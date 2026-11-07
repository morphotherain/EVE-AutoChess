p = '/etc/caddy/Caddyfile'
s = open(p).read()
anchor = '@bad not method GET HEAD'
assert s.count(anchor) == 1, 'anchor count'
lines = s.split('\n')
i = [k for k, l in enumerate(lines) if l.strip() == anchor][0]
ind = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
new = [
    ind + '@bad {',
    ind + '\tnot method GET HEAD',
    ind + '\tnot path /report',
    ind + '}',
    lines[i + 1],
    '',
    ind + '# 1.4) diagnostic report: the only POST endpoint on this site',
    ind + '@report path /report',
    ind + 'handle @report {',
    ind + '\treverse_proxy 127.0.0.1:27102',
    ind + '}',
]
lines[i:i + 2] = new
open('/tmp/Caddyfile.new', 'w').write('\n'.join(lines))
print('patched')
