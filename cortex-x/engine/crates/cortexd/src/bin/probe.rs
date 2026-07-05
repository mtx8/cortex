//! probe — connects to a running cortexd like the macOS app does and
//! exercises the full protocol: snapshot, live stream, copilot, a paper
//! order round-trip, and the kill switch. Exits nonzero on any failure.
//!
//! Usage: cargo run -p cortexd --bin probe [-- ws://127.0.0.1:9601]

use std::collections::BTreeMap;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

fn field<'v>(v: &'v Value, k: &str) -> &'v Value {
    v.get(k).unwrap_or(&Value::Null)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "ws://127.0.0.1:9601".into());
    println!("probe: connecting {url}");
    let (ws, _) = tokio::time::timeout(
        Duration::from_secs(5),
        tokio_tungstenite::connect_async(&url),
    )
    .await??;
    let (mut tx, mut rx) = ws.split();

    let mut counts: BTreeMap<String, u64> = BTreeMap::new();
    let mut failures: Vec<String> = Vec::new();
    let mut got_hello = false;
    let mut snapshot_symbols = 0usize;
    let mut snapshot_bars = 0usize;

    // Phase 1: hello + snapshot must arrive first.
    for _ in 0..2 {
        let msg = tokio::time::timeout(Duration::from_secs(5), rx.next())
            .await?
            .ok_or_else(|| anyhow::anyhow!("connection closed early"))??;
        let v: Value = serde_json::from_str(msg.to_text()?)?;
        match field(&v, "type").as_str().unwrap_or("") {
            "hello" => got_hello = true,
            "snapshot" => {
                let data = field(&v, "data");
                snapshot_symbols = field(data, "symbols").as_array().map(|a| a.len()).unwrap_or(0);
                snapshot_bars = field(data, "bars")
                    .as_object()
                    .map(|o| {
                        o.values()
                            .filter_map(|per| per.as_object())
                            .flat_map(|per| per.values())
                            .filter_map(|arr| arr.as_array())
                            .map(|arr| arr.len())
                            .sum()
                    })
                    .unwrap_or(0);
            }
            other => failures.push(format!("unexpected first frames: {other}")),
        }
    }
    if !got_hello {
        failures.push("no hello frame".into());
    }
    if snapshot_symbols == 0 {
        failures.push("snapshot had no symbols".into());
    }
    println!("probe: hello ok, snapshot symbols={snapshot_symbols} bars={snapshot_bars}");

    // Phase 2: observe the live stream for 15s.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while tokio::time::Instant::now() < deadline {
        let Ok(Some(Ok(msg))) = tokio::time::timeout(Duration::from_secs(3), rx.next()).await
        else {
            continue;
        };
        if let Ok(text) = msg.to_text() {
            if let Ok(v) = serde_json::from_str::<Value>(text) {
                let t = field(&v, "type").as_str().unwrap_or("?").to_string();
                *counts.entry(t).or_insert(0) += 1;
            }
        }
    }
    println!("probe: 15s stream counts = {counts:?}");
    if counts.get("tick").copied().unwrap_or(0) == 0 {
        failures.push("no ticks observed in 15s".into());
    }

    // Phase 3: copilot ask.
    tx.send(Message::text(
        json!({"cmd":"ask_ai","request_id":"probe-1","question":"one-line market read"}).to_string(),
    ))
    .await?;

    // Phase 4: paper order round-trip.
    tx.send(Message::text(
        json!({"cmd":"place_order","symbol":"BTC-USD","side":"buy","qty":0.001,"order_type":"market","limit_px":null}).to_string(),
    ))
    .await?;

    let mut saw_answer = false;
    let mut saw_fill = false;
    let mut saw_position = false;
    let order_deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while tokio::time::Instant::now() < order_deadline && !(saw_answer && saw_fill && saw_position)
    {
        let Ok(Some(Ok(msg))) = tokio::time::timeout(Duration::from_secs(5), rx.next()).await
        else {
            continue;
        };
        let Ok(text) = msg.to_text() else { continue };
        let Ok(v) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        match field(&v, "type").as_str().unwrap_or("") {
            "ai_answer" if field(&v, "request_id").as_str() == Some("probe-1") => {
                saw_answer = true;
                println!(
                    "probe: copilot [{}]: {}",
                    field(&v, "model").as_str().unwrap_or("?"),
                    field(&v, "answer").as_str().unwrap_or("").chars().take(160).collect::<String>()
                );
            }
            "fill" if field(&v, "symbol").as_str() == Some("BTC-USD") => {
                saw_fill = true;
                println!(
                    "probe: filled {} @ {}",
                    field(&v, "qty"),
                    field(&v, "px")
                );
            }
            "position" if field(&v, "symbol").as_str() == Some("BTC-USD") => {
                saw_position = true;
            }
            _ => {}
        }
    }
    if !saw_answer {
        failures.push("no ai_answer for probe ask".into());
    }
    if !saw_fill {
        failures.push("manual paper order did not fill".into());
    }
    if !saw_position {
        failures.push("no position update after fill".into());
    }

    // Phase 5: kill switch blocks, then releases.
    tx.send(Message::text(
        json!({"cmd":"set_kill_switch","engaged":true,"reason":"probe test"}).to_string(),
    ))
    .await?;
    tx.send(Message::text(
        json!({"cmd":"place_order","symbol":"BTC-USD","side":"buy","qty":0.001,"order_type":"market","limit_px":null}).to_string(),
    ))
    .await?;
    let mut saw_kill = false;
    let mut saw_reject = false;
    let kill_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while tokio::time::Instant::now() < kill_deadline && !(saw_kill && saw_reject) {
        let Ok(Some(Ok(msg))) = tokio::time::timeout(Duration::from_secs(3), rx.next()).await
        else {
            continue;
        };
        let Ok(text) = msg.to_text() else { continue };
        let Ok(v) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        match field(&v, "type").as_str().unwrap_or("") {
            "risk" if field(&v, "kill_switch").as_bool() == Some(true) => saw_kill = true,
            "order_update" => {
                if field(field(&v, "status"), "state").as_str() == Some("rejected_by_risk") {
                    saw_reject = true;
                    println!(
                        "probe: kill switch rejected order: {}",
                        field(field(&v, "status"), "reason").as_str().unwrap_or("?")
                    );
                }
            }
            _ => {}
        }
    }
    if !saw_kill {
        failures.push("kill switch status not broadcast".into());
    }
    if !saw_reject {
        failures.push("order not rejected under kill switch".into());
    }
    tx.send(Message::text(
        json!({"cmd":"set_kill_switch","engaged":false,"reason":"probe done"}).to_string(),
    ))
    .await?;

    // Phase 6: full option chain for SPY (CBOE fetch + BS enrichment).
    tx.send(Message::text(
        json!({"cmd":"get_options_chain","underlying":"SPY"}).to_string(),
    ))
    .await?;
    let mut saw_chain = false;
    let chain_deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    while tokio::time::Instant::now() < chain_deadline && !saw_chain {
        let Ok(Some(Ok(msg))) = tokio::time::timeout(Duration::from_secs(5), rx.next()).await
        else {
            continue;
        };
        let Ok(text) = msg.to_text() else { continue };
        let Ok(v) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        if field(&v, "type").as_str() == Some("options_chain") {
            let n = field(&v, "contracts").as_array().map(|a| a.len()).unwrap_or(0);
            let n_exp = field(&v, "expirations").as_array().map(|a| a.len()).unwrap_or(0);
            let with_iv = field(&v, "contracts")
                .as_array()
                .map(|a| a.iter().filter(|c| !c["iv"].is_null()).count())
                .unwrap_or(0);
            println!(
                "probe: SPY chain expiry {} — {n} contracts ({with_iv} with iv), {n_exp} expirations, spot {}",
                field(&v, "expiry"), field(&v, "underlying_px")
            );
            saw_chain = n > 10 && n_exp > 3;
        }
    }
    if !saw_chain {
        failures.push("no usable options chain for SPY".into());
    }
    // Flatten the probe's position so repeated runs stay clean.
    tx.send(Message::text(
        json!({"cmd":"flatten_all","reason":"probe cleanup"}).to_string(),
    ))
    .await?;
    tokio::time::sleep(Duration::from_millis(500)).await;

    if failures.is_empty() {
        println!("probe: ALL CHECKS PASSED");
        Ok(())
    } else {
        for f in &failures {
            eprintln!("probe FAILURE: {f}");
        }
        anyhow::bail!("{} failures", failures.len())
    }
}
