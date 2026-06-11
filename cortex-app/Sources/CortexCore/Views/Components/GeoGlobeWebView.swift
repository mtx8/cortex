import SwiftUI
import WebKit

/// A self-contained orthographic globe rendered in a single WKWebView document
/// (omniscient's WebView-isolation pattern). No external CDN, no egress, no keys —
/// the page is an inline string and all data is pushed from Swift via
/// `window.cortexGlobe.setData(...)`. Tracks vessels (tankers in ember), seismic
/// events, and the world oil chokepoints. The photorealistic Cesium-Ion 3D globe
/// is a drop-in upgrade (bundle CesiumJS + an Ion token in Keychain) for a later pass.
public struct GeoGlobeWebView: NSViewRepresentable {
    public var payloadJSON: String

    public init(payloadJSON: String) {
        self.payloadJSON = payloadJSON
    }

    public func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.loadHTMLString(Self.html, baseURL: nil)
        context.coordinator.webView = web
        return web
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.push(payloadJSON)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: String?

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let p = pending { pending = nil; push(p) }
        }

        func push(_ json: String) {
            guard let web = webView else { return }
            guard loaded else { pending = json; return }
            web.evaluateJavaScript("window.cortexGlobe && window.cortexGlobe.setData(\(json));",
                                   completionHandler: nil)
        }
    }

    // Inline page. IMPORTANT: no Swift interpolation and no backslashes below.
    static let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<style>
  html,body { margin:0; height:100%; background:#0A0A0C; overflow:hidden; }
  #c { width:100vw; height:100vh; display:block; cursor:grab; }
  #c:active { cursor:grabbing; }
</style>
</head>
<body>
<canvas id="c"></canvas>
<script>
(function(){
  var cv = document.getElementById('c');
  var ctx = cv.getContext('2d');
  var DPR = Math.max(1, window.devicePixelRatio || 1);
  var W=0, H=0, R=0, cx=0, cy=0;
  var lon0 = 0.0;        // rotation (deg)
  var lat0 = 12.0;       // tilt (deg)
  var dragging=false, autoRotate=true, lastX=0, lastY=0;
  var data = { vessels:[], events:[] };
  var EMBER = '#E08A2A', BONE = '#F5EFE4', HI = '#D8233A';

  var CHOKES = [
    ['Hormuz',26.57,56.25],['Malacca',2.5,101.5],['Suez',30.5,32.35],
    ['Bab el-Mandeb',12.58,43.33],['Bosphorus',41.1,29.07],['Gibraltar',35.97,-5.6],
    ['Panama',9.1,-79.7],['Danish Str.',55.7,12.7],['Good Hope',-34.36,18.47]
  ];

  function resize(){
    W = cv.clientWidth; H = cv.clientHeight;
    cv.width = Math.floor(W*DPR); cv.height = Math.floor(H*DPR);
    ctx.setTransform(DPR,0,0,DPR,0,0);
    R = Math.min(W,H)*0.42; cx = W/2; cy = H/2;
  }
  window.addEventListener('resize', resize);

  function rad(d){ return d*Math.PI/180; }
  // Orthographic projection. Returns [x,y,visible].
  function project(lat, lon){
    var p = rad(lat), l = rad(lon - lon0), p0 = rad(lat0);
    var cosc = Math.sin(p0)*Math.sin(p) + Math.cos(p0)*Math.cos(p)*Math.cos(l);
    var x = R*Math.cos(p)*Math.sin(l);
    var y = R*(Math.cos(p0)*Math.sin(p) - Math.sin(p0)*Math.cos(p)*Math.cos(l));
    return [cx + x, cy - y, cosc >= 0];
  }

  function drawSphere(){
    var g = ctx.createRadialGradient(cx-R*0.3, cy-R*0.3, R*0.2, cx, cy, R);
    g.addColorStop(0, '#15171c'); g.addColorStop(1, '#0b0d11');
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI*2); ctx.fillStyle = g; ctx.fill();
    ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(245,239,228,0.10)';
    // graticule
    for (var lo=-180; lo<180; lo+=30){
      ctx.beginPath(); var started=false;
      for (var la=-90; la<=90; la+=4){
        var pr = project(la, lo); if(!pr[2]){ started=false; continue; }
        if(!started){ ctx.moveTo(pr[0],pr[1]); started=true; } else ctx.lineTo(pr[0],pr[1]);
      }
      ctx.stroke();
    }
    for (var la2=-60; la2<=60; la2+=30){
      ctx.beginPath(); var st2=false;
      for (var lo2=-180; lo2<=180; lo2+=4){
        var pr2 = project(la2, lo2); if(!pr2[2]){ st2=false; continue; }
        if(!st2){ ctx.moveTo(pr2[0],pr2[1]); st2=true; } else ctx.lineTo(pr2[0],pr2[1]);
      }
      ctx.stroke();
    }
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI*2);
    ctx.strokeStyle = 'rgba(245,239,228,0.22)'; ctx.lineWidth = 1.2; ctx.stroke();
  }

  function drawChokes(){
    ctx.font = '10px -apple-system, sans-serif';
    for (var i=0;i<CHOKES.length;i++){
      var c = CHOKES[i], pr = project(c[1], c[2]); if(!pr[2]) continue;
      ctx.beginPath(); ctx.arc(pr[0], pr[1], 7, 0, Math.PI*2);
      ctx.strokeStyle = 'rgba(224,138,42,0.85)'; ctx.lineWidth=1.4; ctx.stroke();
      ctx.fillStyle = 'rgba(245,239,228,0.55)'; ctx.fillText(c[0], pr[0]+9, pr[1]+3);
    }
  }

  function drawVessels(){
    var v = data.vessels, tn=0;
    for (var i=0;i<v.length;i++){
      var pr = project(v[i][0], v[i][1]); if(!pr[2]) continue;
      var tanker = v[i][2] > 0.5;
      ctx.beginPath(); ctx.arc(pr[0], pr[1], tanker?2.0:1.1, 0, Math.PI*2);
      ctx.fillStyle = tanker ? EMBER : 'rgba(245,239,228,0.45)';
      ctx.fill(); if(tanker) tn++;
    }
    return tn;
  }

  function drawEvents(t){
    var e = data.events;
    for (var i=0;i<e.length;i++){
      var pr = project(e[i][0], e[i][1]); if(!pr[2]) continue;
      var m = e[i][2] || 1, pulse = 3 + (m) * 1.5 + Math.sin(t/400 + i)*1.5;
      ctx.beginPath(); ctx.arc(pr[0], pr[1], pulse, 0, Math.PI*2);
      ctx.strokeStyle = 'rgba(216,35,58,0.7)'; ctx.lineWidth=1.2; ctx.stroke();
    }
  }

  function frame(t){
    if (autoRotate && !dragging) lon0 = (lon0 + 0.08) % 360;
    ctx.clearRect(0,0,W,H);
    drawSphere(); drawChokes(); drawVessels(); drawEvents(t);
    requestAnimationFrame(frame);
  }

  cv.addEventListener('mousedown', function(e){ dragging=true; autoRotate=false; lastX=e.clientX; lastY=e.clientY; });
  window.addEventListener('mouseup', function(){ dragging=false; });
  window.addEventListener('mousemove', function(e){
    if(!dragging) return;
    lon0 -= (e.clientX - lastX) * 0.4;
    lat0 = Math.max(-80, Math.min(80, lat0 + (e.clientY - lastY) * 0.3));
    lastX=e.clientX; lastY=e.clientY;
  });
  cv.addEventListener('dblclick', function(){ autoRotate = !autoRotate; });

  window.cortexGlobe = {
    setData: function(d){ if(d && d.vessels){ data = d; } }
  };

  resize();
  requestAnimationFrame(frame);
})();
</script>
</body>
</html>
"""
}
