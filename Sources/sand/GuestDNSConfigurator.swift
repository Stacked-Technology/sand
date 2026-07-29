import Foundation

enum GuestDNSConfigurator {
    static func configurationCommand(
        for config: Config.RunOptions.GuestDNS
    ) -> String {
        let service = shellQuote(config.networkService)
        let servers = config.servers.map(shellQuote)
        let serverArguments = servers.joined(separator: " ")
        let expectedServers = servers.joined(separator: " ")

        return """
if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
  echo "vm.run.guestDNS currently requires a macOS guest" >&2
  exit 1
fi
service_name=\(service)
service_device="$(/usr/sbin/networksetup -listnetworkserviceorder |
  /usr/bin/awk -v wanted="$service_name" '
    /^\\([0-9]+\\) / {
      name = $0
      sub(/^\\([0-9]+\\) /, "", name)
      matched = (name == wanted)
      next
    }
    matched && /Device: / {
      device = $0
      sub(/^.*Device: /, "", device)
      sub(/\\).*$/, "", device)
      print device
      exit
    }
  ')"
default_device="$(/sbin/route -n get default |
  /usr/bin/awk '/interface:/{print $2; exit}')"
if [ -z "$service_device" ] || [ "$service_device" != "$default_device" ]; then
  echo "guest DNS network service is not the active default-route service" >&2
  exit 1
fi
/usr/sbin/networksetup -getinfo \(service) |
  /usr/bin/grep -Eq '^IP address: [0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' || {
  echo "guest DNS network service is not active" >&2
  exit 1
}
if ! /usr/bin/sudo -n /usr/sbin/networksetup -setdnsservers \(service) \(serverArguments); then
  echo "failed to configure guest DNS" >&2
  exit 1
fi
configured_dns="$(/usr/sbin/networksetup -getdnsservers \(service))" || {
  echo "failed to read configured guest DNS" >&2
  exit 1
}
expected_dns="$(/usr/bin/printf '%s\\n' \(expectedServers))"
if [ "$configured_dns" != "$expected_dns" ]; then
  echo "configured guest DNS does not exactly match requested servers" >&2
  exit 1
fi
if ! /usr/bin/dscacheutil -flushcache; then
  echo "failed to flush guest DNS cache" >&2
  exit 1
fi
echo "Guest DNS configured"
"""
    }

    static func probeCommand(for config: Config.RunOptions.GuestDNS) -> String {
        let probeHost = shellQuote(config.probeHost)
        let servers = config.servers.map(shellQuote).joined(separator: " ")
        return """
if ! /usr/bin/dscacheutil -flushcache; then
  echo "failed to flush guest DNS cache before isolated probe" >&2
  exit 1
fi
for resolver in \(servers); do
  if ! /usr/bin/dig +time=5 +tries=1 +short "@$resolver" \(probeHost) A |
    /usr/bin/grep -Eq '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$'; then
    echo "configured guest DNS server failed isolated probe" >&2
    exit 1
  fi
done
if ! /usr/bin/dscacheutil -q host -a name \(probeHost) |
  /usr/bin/grep -Eq '^ip_address: '; then
  echo "guest DNS probe failed" >&2
  exit 1
fi
echo "Guest DNS probe passed after network isolation"
"""
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
