<p align="center"><img src="Resources/logo.png" width="160" alt="Fence logo"></p>

# Fence

Menu bar app for macOS. It blocks access to services while your public IP is in a region they do not support.

## Who this is for

Some online services tie the account to the region of the public IP. A request from a region outside their list can get the account restricted, even when the request was an accident.

An accident is easy. You need a service that works only from an IP in a specific region: a government portal, a bank, a tax office, a telecom account. So you turn on a VPN with an exit in that region. While that VPN is on, every app on the machine goes out through the same exit: the terminal, the desktop apps, the browser tabs. Every one of them now talks to its servers from that region.

Turning the VPN on and off by hand does not solve it. Desktop apps and command line tools keep open connections and send requests in the background. A forgotten session can send a request seconds after the VPN comes up.

Fence closes that gap. It watches the network, and the moment the route changes it cuts access to the configured services. Access comes back only after the daemon confirms that the public IP is in a region outside the blocked set. You keep working with the local service. The fenced services show a network error until you turn the VPN off.

## What it is not

- It is not a tool to reach a service from a region it does not serve. It does the opposite.
- It is not a VPN kill switch. Only the hosts of the configured services are affected.
- It is not a replacement for split tunneling. If your VPN client can route only the local service through the tunnel, do that. Fence then stays as insurance.

## How it works

Two processes:

- `fence-daemon` runs as root through launchd. It watches the network, checks the   country of the public IP and sets or removes the block.
- `Fence.app` runs as the user in the menu bar. It shows the state and sends commands.

The daemon fails closed:

1. On start and on every network change it sets the block at once.
2. Then it asks the country from ipinfo.io, country.is, ifconfig.co or ip-api.com.
3. If the country is in the blocked set the block stays. If the lookup fails the block stays.
4. Only a confirmed country outside the set removes the block.
5. It rechecks every 60 seconds, and every 15 seconds while blocked.
6. A watchdog pings the main queue every 15 seconds. After 90 seconds without an answer the daemon exits. The block stays in place and launchd starts a fresh daemon.

The block has two layers:

- `/etc/hosts` points the hosts of the enabled services to `127.0.0.1` and `::1`. New connections get "connection refused".
- A pf anchor `com.apple/fence` drops packets to the known IP addresses of the hosts that have `pf` on in the config. This kills open keep-alive connections.

## Services and config

The daemon keeps its settings in `/Library/Application Support/Fence/config.json`. The file holds two lists: the regions to block and the services to fence. The daemon writes the file with defaults on the first start. Edit it by hand or use the Services submenu. The daemon picks up a hand edit within 5 seconds.

```json
{
  "blockedCountries": ["RU", "BY", "CN", "HK", "MO", "IR", "KP", "SY", "CU", "VE", "AF", "MM", "YE"],
  "services": [
    { "id": "anthropic", "name": "Anthropic / Claude", "enabled": true, "pf": true,
      "hosts": ["api.anthropic.com", "claude.ai", "..."] },
    { "id": "openai", "name": "OpenAI / ChatGPT", "enabled": true,
      "hosts": ["api.openai.com", "chatgpt.com", "..."] }
  ]
}
```

Services in the default config. Each one has a published region policy or a record of IP based restrictions. The ones with no clear policy ship disabled:

| id         | Service                        | Default | Why                                            |
|------------|--------------------------------|---------|------------------------------------------------|
| anthropic  | Anthropic / Claude             | on      | Supported regions policy, accounts get blocked |
| openai     | OpenAI / ChatGPT               | on      | Supported regions policy, policy warns of bans |
| cursor     | Cursor                         | on      | Blocks IPs from some regions since 2026        |
| gemini     | Google Gemini API / AI Studio  | on      | Not available in some regions                  |
| copilot    | GitHub Copilot                 | off     | Export control list, no IP bans reported       |
| notion     | Notion                         | off     | Closed for some regions since 2024             |
| xai        | xAI / Grok                     | off     | No official policy found                       |
| perplexity | Perplexity                     | off     | No official policy found                       |
| mistral    | Mistral                        | off     | No official policy found                       |

To add your own service, for example a bank that flags logins from a foreign IP, append an object to `services`:

```json
{ "id": "mybank", "name": "My Bank", "enabled": true, "hosts": ["app.mybank.example", "api.mybank.example"] }
```

The `pf` flag adds the second layer: pf drops packets to the resolved addresses of the hosts. Turn it on only for hosts with dedicated addresses. Hosts behind Cloudflare or Google front ends share addresses with other sites, and pf would block those sites too while the block is active. The hosts layer alone is enough for a new connection to fail.

The default `blockedCountries` list is the set of regions that the strictest service in the table did not serve as of 2026-10-28. Edit the list to match the services you use.

## Language

The menu has a Language item with English and Russian. English is the default. The choice is stored in the app defaults.

## Install

```sh
sudo ./install.sh
```

The script builds both targets, installs the daemon, installs the app to `/Applications`, and registers the app as a login item.

## Remove

```sh
sudo ./uninstall.sh
```

The script stops the daemon, cleans `/etc/hosts` and the pf anchor, and removes the app.

## CLI

```sh
/usr/local/libexec/fence-daemon status      # JSON state
/usr/local/libexec/fence-daemon manual-on   # set the manual block
/usr/local/libexec/fence-daemon manual-off  # clear the manual block
/usr/local/libexec/fence-daemon recheck     # check the country now
/usr/local/libexec/fence-daemon services    # list services and their state
/usr/local/libexec/fence-daemon service-on cursor
/usr/local/libexec/fence-daemon service-off cursor
/usr/local/libexec/fence-daemon reload      # re-read config.json now
/usr/local/libexec/fence-daemon geo         # one geo lookup, no daemon needed
```

Log: `/Library/Logs/Fence/daemon.log`.

## Test without root

```sh
./build.sh
export FENCE_PREFIX=/some/short/dir FENCE_SOCKET=/some/short/dir/s
mkdir -p "$FENCE_PREFIX/etc" && cp /etc/hosts "$FENCE_PREFIX/etc/hosts"
./build/fence-daemon run --dry-run
```

Dry run edits the hosts copy under the prefix and skips pf and the DNS flush.
