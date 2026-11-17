#!/usr/bin/env perl
# Agent board for herdr. Run: perl herdr_kanban.pl [port]
use strict;
use warnings;
use HTTP::Daemon;
use HTTP::Response;
use JSON::PP;
use URI;

my $port = shift // 8765;
my %since;    # pane_id => [status, epoch] : herdr has no timestamps, so track status changes ourselves

sub herdr { open(my $fh, '-|', 'herdr', @_) or return ''; local $/; my $out = <$fh> // ''; close $fh; $out }

sub agents {
    my $list = eval { decode_json(herdr(qw(agent list)))->{result}{agents} } || [];
    my $now  = time;
    for my $a (@$list) {
        my $s = $since{ $a->{pane_id} };
        $since{ $a->{pane_id} } = $s = [ $a->{agent_status} // '', $now ]
            if !$s || $s->[0] ne ($a->{agent_status} // '');
        $a->{since} = $s->[1];
    }
    $list;
}

my $page = do { local $/; <DATA> };
my $d = HTTP::Daemon->new(LocalAddr => '127.0.0.1', LocalPort => $port, ReuseAddr => 1) or die "listen: $!";
print "http://127.0.0.1:$port\n";

# ponytail: single-threaded, one request at a time; fine for one browser tab polling every 3s
while (my $c = $d->accept) {
    while (my $r = $c->get_request) {
        my $u    = URI->new($r->uri);
        my %q    = $u->query_form;
        my $pane = ($q{pane} // '') =~ /^[\w:]+$/ ? $q{pane} : undef;
        my $p    = $u->path;
        my ($code, $type, $body) = (404, 'text/plain', 'not found');
        if    ($p eq '/' && $r->method eq 'GET')             { ($code, $type, $body) = (200, 'text/html; charset=utf-8', $page) }
        elsif ($p eq '/agents')                              { ($code, $type, $body) = (200, 'application/json', encode_json(agents())) }
        elsif ($p eq '/read' && $pane)                       { ($code, $type, $body) = (200, 'text/plain; charset=utf-8', herdr(qw(agent read), $pane, qw(--lines 40))) }
        elsif ($p eq '/focus' && $pane && $r->method eq 'POST') { herdr(qw(agent focus), $pane); ($code, $body) = (204, '') }
        $c->send_response(HTTP::Response->new($code, undef, [ 'Content-Type' => $type ], $body));
    }
    $c->close;
}

__DATA__
<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>herdr board</title>
<style>
:root{--bg:#f6f6f4;--fg:#222;--mut:#888;--line:#e2e2e0;--hov:#ececea}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#ddd;--mut:#777;--line:#26262a;--hov:#1e1e22}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,system-ui,sans-serif}
header{display:flex;gap:12px;align-items:baseline;padding:10px 16px;border-bottom:1px solid var(--line)}
header b{font-size:15px}header span{color:var(--mut);font-size:13px}header .r{margin-left:auto}
main{padding:0 16px 16px}
h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;margin:16px 0 4px;color:var(--c)}
.row{display:grid;grid-template-columns:16px 210px minmax(0,1fr) 170px 56px;gap:8px;align-items:baseline;
 padding:8px 4px;border-top:1px solid var(--line);cursor:pointer}
.row:hover{background:var(--hov)}.row.focused{box-shadow:inset 2px 0 var(--c)}
.dot{color:var(--c)}.n{font:14px ui-monospace,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.t{overflow-wrap:anywhere}.m,.age{color:var(--mut);font-size:13px}.age{text-align:right}
.m{font-family:ui-monospace,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tg{background:none;border:0;color:var(--mut);font-size:13px;padding:0 0 0 6px;cursor:pointer}
pre{grid-column:2/-1;font-size:13px;white-space:pre-wrap;overflow-wrap:anywhere;max-height:260px;overflow:auto;margin:4px 0 0;color:var(--mut)}
@media (max-width:700px){.row{grid-template-columns:14px minmax(0,1fr) 48px}.n{grid-column:2}.t{grid-column:2/-1}.m{display:none}}
</style></head><body>
<header><b>herdr board</b><span id="sum"></span><span class="r" id="up"></span></header><main id="b"></main>
<script>
const SECS=[["needs you",["blocked","done"],"#e5484d"],["working",["working"],"#3e8ed0"],["idle",null,"#8b8d98"]];
const open=new Set();
const ago=s=>{const d=Date.now()/1000-s;return d<60?"now":d<3600?Math.floor(d/60)+"m":d<86400?Math.floor(d/3600)+"h":Math.floor(d/86400)+"d"};
const el=(t,c,txt)=>{const e=document.createElement(t);if(c)e.className=c;if(txt!=null)e.textContent=txt;return e};
async function load(){
  const agents=await (await fetch("/agents")).json();
  const b=document.getElementById("b");b.innerHTML="";const counts=[];
  for(const [label,keys,color] of SECS){
    const list=agents.filter(a=>keys?keys.includes(a.agent_status):!["blocked","done","working"].includes(a.agent_status))
      .sort((x,y)=>x.since-y.since);
    counts.push(`${list.length} ${label}`);
    if(!list.length)continue;
    const h=el("h2",null,`${label} ${list.length}`);h.style.setProperty("--c",color);b.append(h);
    for(const a of list){
      const r=el("div","row"+(a.focused?" focused":""));r.style.setProperty("--c",color);
      const t=el("div","t",a.terminal_title_stripped||a.pane_id);
      if(a.agent_status==="done")t.prepend(el("span","m","done · "));
      const tg=el("button","tg",open.has(a.pane_id)?"▾ 出力":"▸ 出力");t.append(tg);
      r.append(el("span","dot","●"),el("span","n",(a.cwd||"").split("/").pop()||a.pane_id),t,
        el("span","m",`${a.agent} · ${a.pane_id}`),el("span","age",ago(a.since)));
      tg.onclick=e=>{e.stopPropagation();open.has(a.pane_id)?open.delete(a.pane_id):open.add(a.pane_id);load()};
      if(open.has(a.pane_id)){const p=el("pre");r.append(p);peek(a.pane_id,p);p.onclick=e=>e.stopPropagation()}
      r.onclick=()=>fetch("/focus?pane="+encodeURIComponent(a.pane_id),{method:"POST"}).then(load);
      b.append(r);
    }
  }
  const n=agents.filter(a=>["blocked","done"].includes(a.agent_status)).length;
  document.title=(n?`(${n}) `:"")+"herdr board";
  document.getElementById("sum").textContent=counts.join(" · ");
  document.getElementById("up").textContent=new Date().toLocaleTimeString()+" 更新 · 行クリックでフォーカス";
}
async function peek(p,pre){pre.textContent=await (await fetch("/read?pane="+encodeURIComponent(p))).text()}
load();setInterval(load,3000);
</script></body></html>
