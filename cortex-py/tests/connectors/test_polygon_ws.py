import pytest
from cortex.connectors.polygon.ws_client import (
    PolygonWebSocket,
    PolygonConfig,
    PolygonFeed,
    PolygonTrade,
    PolygonQuote,
    PolygonAggregate,
)


def make_client() -> PolygonWebSocket:
    return PolygonWebSocket(PolygonConfig(api_key="test_key"))


class TestPolygonConfig:
    def test_defaults(self):
        config = PolygonConfig()
        assert config.ws_url == "wss://socket.polygon.io/stocks"
        assert config.max_subscriptions == 500

    def test_custom_api_key(self):
        config = PolygonConfig(api_key="abc123")
        assert config.api_key == "abc123"


class TestSubscriptionManagement:
    def test_subscribe_trades(self):
        client = make_client()
        subs = client.subscribe(PolygonFeed.TRADES, ["AAPL", "MSFT"])
        assert "T.AAPL" in subs
        assert "T.MSFT" in subs
        assert len(client.get_subscriptions()) == 2

    def test_subscribe_multiple_feeds(self):
        client = make_client()
        client.subscribe(PolygonFeed.TRADES, ["AAPL"])
        client.subscribe(PolygonFeed.QUOTES, ["AAPL"])
        client.subscribe(PolygonFeed.MINUTE_AGG, ["AAPL"])
        subs = client.get_subscriptions()
        assert "T.AAPL" in subs
        assert "Q.AAPL" in subs
        assert "AM.AAPL" in subs

    def test_unsubscribe(self):
        client = make_client()
        client.subscribe(PolygonFeed.TRADES, ["AAPL", "MSFT"])
        client.unsubscribe(PolygonFeed.TRADES, ["AAPL"])
        assert "T.AAPL" not in client.get_subscriptions()
        assert "T.MSFT" in client.get_subscriptions()

    def test_no_duplicate_subscriptions(self):
        client = make_client()
        client.subscribe(PolygonFeed.TRADES, ["AAPL"])
        client.subscribe(PolygonFeed.TRADES, ["AAPL"])
        assert len(client.get_subscriptions()) == 1


class TestMessageParsing:
    def test_parse_trade(self):
        client = make_client()
        raw = '[{"ev":"T","sym":"AAPL","p":150.25,"s":100,"t":1708300000000,"c":[12,37]}]'
        results = client.parse_message(raw)
        assert len(results) == 1
        trade = results[0]
        assert isinstance(trade, PolygonTrade)
        assert trade.symbol == "AAPL"
        assert trade.price == 150.25
        assert trade.size == 100
        assert 12 in trade.conditions

    def test_parse_quote(self):
        client = make_client()
        raw = '[{"ev":"Q","sym":"MSFT","bp":400.10,"ap":400.15,"bs":200,"as":300,"t":1708300000000}]'
        results = client.parse_message(raw)
        assert len(results) == 1
        quote = results[0]
        assert isinstance(quote, PolygonQuote)
        assert quote.symbol == "MSFT"
        assert quote.bid == 400.10
        assert quote.ask == 400.15

    def test_parse_aggregate(self):
        client = make_client()
        raw = '[{"ev":"AM","sym":"TSLA","o":200.0,"h":205.0,"l":199.0,"c":203.0,"v":5000000,"vw":202.5,"s":1708300000000}]'
        results = client.parse_message(raw)
        assert len(results) == 1
        agg = results[0]
        assert isinstance(agg, PolygonAggregate)
        assert agg.symbol == "TSLA"
        assert agg.close == 203.0
        assert agg.volume == 5000000

    def test_parse_multiple_events(self):
        client = make_client()
        raw = '[{"ev":"T","sym":"AAPL","p":150.0,"s":50,"t":1},{"ev":"T","sym":"MSFT","p":400.0,"s":100,"t":2}]'
        results = client.parse_message(raw)
        assert len(results) == 2
        assert results[0].symbol == "AAPL"
        assert results[1].symbol == "MSFT"

    def test_parse_invalid_json(self):
        client = make_client()
        results = client.parse_message("not json")
        assert results == []

    def test_parse_non_array(self):
        client = make_client()
        results = client.parse_message('{"ev":"T"}')
        assert results == []

    def test_message_counter(self):
        client = make_client()
        assert client.messages_received == 0
        client.parse_message('[{"ev":"T","sym":"AAPL","p":150.0,"s":50,"t":1}]')
        assert client.messages_received == 1
        client.parse_message('[{"ev":"T","sym":"A","p":1,"s":1,"t":1},{"ev":"Q","sym":"B","bp":1,"ap":2,"bs":1,"as":1,"t":1}]')
        assert client.messages_received == 3


class TestClientState:
    def test_initial_state(self):
        client = make_client()
        assert client.is_connected is False
        assert client.is_authenticated is False
        assert client.messages_received == 0

    def test_handler_registration(self):
        client = make_client()
        client.on_trade(lambda t: None)
        client.on_quote(lambda q: None)
        client.on_aggregate(lambda a: None)
        assert len(client._trade_handlers) == 1
        assert len(client._quote_handlers) == 1
        assert len(client._agg_handlers) == 1

    def test_to_dict(self):
        client = make_client()
        d = client.to_dict()
        assert "connected" in d
        assert "subscriptions" in d
        assert "messages_received" in d
