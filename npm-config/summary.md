# NPM configuration

Exported from NPM on 2026-10-23 by `export_npm_config.sh`. Secrets are redacted; see the script header.

## Proxy hosts

| Domains | Upstream | Options | Access list | Certificate | Advanced |
| --- | --- | --- | --- | --- | --- |
| cal.one137.dev<br>radicale.one137.dev | `http://ct-radicale:5232` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev | custom |
| dockerhost-st.one137.dev<br>syncthing-dh.one137.dev | `http://ct-syncthing:8384` | WS, HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| dufs.one137.dev<br>files.one137.dev | `http://ct-dufs:5000` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev | custom |
| immich.one137.dev | `http://immich_server:2283` | WS, HTTP2, force SSL, block exploits, cache | LAN & Wireguard | one137.dev, *.one137.dev | custom |
| jellyfin.one137.dev | `http://ct-jellyfin:8096` | WS, HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| npm.one137.dev | `http://ct-npm:81` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| one137.dev | `http://STATIC_FILES:1` | HTTP2, force SSL, block exploits | _public_ | one137.dev, *.one137.dev | custom, 2 location(s) |
| pihole1.one137.dev | `http://pihole1:80` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| pihole2.one137.dev | `http://ct-pihole:80` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| portainer.one137.dev | `https://ct-portainer:9443` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| proxmox.one137.dev | `https://proxmox:8006` | WS, HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| restic.one137.dev | `http://truenas:30248` | HTTP2, force SSL | LAN & Wireguard | one137.dev, *.one137.dev |  |
| router.one137.dev<br>zyxel.one137.dev | `http://router:80` | WS, HTTP2, force SSL, block exploits, trust X-Forwarded-Proto | LAN & Wireguard | one137.dev, *.one137.dev |  |
| syncthing.one137.dev | `https://truenas:20910` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| transmission.one137.dev | `http://ct-transmission:9091` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| truenas.one137.dev | `http://truenas:80` | WS, HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| upsnap.one137.dev | `http://172.16.0.1:8090` | HTTP2, force SSL | LAN & Wireguard | one137.dev, *.one137.dev |  |
| uptime-kuma.one137.dev | `http://ct-uptime-kuma:3001` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |
| wg-easy.one137.dev<br>wireguard-easy.one137.dev | `http://ct-wireguard-easy:51821` | HTTP2, force SSL, block exploits | LAN & Wireguard | one137.dev, *.one137.dev |  |

## Paths inside a proxy host

| Host | Path | Upstream |
| --- | --- | --- |
| one137.dev | `/comments-api` | `http://ct-comments-api:3000` |
| one137.dev | `/clipse-api/` | `http://ct-clipse-api:8080/` |

## Streams

| Incoming port | Forwards to | Protocol |
| --- | --- | --- |
| `8025` | `ct-mailrise:8025` | TCP |
| `22000` | `ct-syncthing:22000` | TCP + UDP |
| `27017` | `ct-mongodb:27017` | TCP |
| `WG_PORT` | `ct-wireguard-easy:WG_PORT` | UDP |

## Access lists

### LAN & Wireguard

- Satisfy: all
- Pass auth upstream: no
- Used by 18 proxy host(s)
- Rules:
    - `allow 192.168.137.0/24`
    - `allow 10.100.0.3/32`

## Certificates

| Name | Domains | Provider | Expires |
| --- | --- | --- | --- |
| one137.dev, *.one137.dev | *.one137.dev<br>one137.dev | letsencrypt | 2027-01-07 20:42:18 |

## Advanced configuration

These snippets are typed into NPM's UI and live only in its database.

They can also rely on `data/nginx/custom/http_top.conf`, which NPM includes at the top of its `http` block (a log format, for one). That file is not API data: [`http_top.conf`](http_top.conf) is a copy taken by hand, with `scp dockerhost:/srv/docker/volumes/npm/data/nginx/custom/http_top.conf .`. Its commented-out `set_real_ip_from` lines don't mean real-IP is off: NPM's own `nginx.conf` already sets them, with `real_ip_header X-Real-IP`.

### cal.one137.dev, radicale.one137.dev

```nginx
client_max_body_size 100m;
```

### dufs.one137.dev, files.one137.dev

```nginx
client_max_body_size 100m;
```

### immich.one137.dev

```nginx
client_max_body_size 100m;
```

### one137.dev

```nginx
location / { 
  root /data/nginx/custom/one137-web;
  try_files $uri $uri.html $uri/ =404;

  access_log /data/logs/proxy-host-1_access.log default_plus_cf;

  allow 192.168.137.0/24; # lan
  allow 10.100.0.3/32;    # wg-easy
  allow 172.21.0.2/32;    # cloudflared
  deny all;
}

location = /health {
    access_log off;
    root /data/nginx/custom/one137-web;
    try_files /index.html =404;
}
```

