import XCTest
@testable import sand

final class GuestDNSConfiguratorTests: XCTestCase {
    func testBuildsFailClosedMacOSDNSCommand() {
        let config = Config.RunOptions.GuestDNS(
            networkService: "USB 10/100/1000 LAN",
            servers: ["1.1.1.1", "8.8.8.8"]
        )

        let command = GuestDNSConfigurator.configurationCommand(for: config)

        XCTAssertTrue(command.contains(#"/usr/bin/uname -s"#))
        XCTAssertTrue(command.contains(#"-listnetworkserviceorder"#))
        XCTAssertTrue(command.contains(#"/sbin/route -n get default"#))
        XCTAssertTrue(
            command.contains(
                #"[ "$service_device" != "$default_device" ]"#
            )
        )
        XCTAssertTrue(command.contains(#"-getinfo 'USB 10/100/1000 LAN'"#))
        XCTAssertTrue(command.contains(#"/usr/bin/sudo -n /usr/sbin/networksetup"#))
        XCTAssertTrue(command.contains(#"-setdnsservers 'USB 10/100/1000 LAN' '1.1.1.1' '8.8.8.8'"#))
        XCTAssertTrue(command.contains(#"-getdnsservers 'USB 10/100/1000 LAN'"#))
        XCTAssertTrue(command.contains(#"if ! /usr/bin/sudo -n"#))
        XCTAssertTrue(command.contains(#"if [ "$configured_dns" != "$expected_dns" ]"#))
        XCTAssertTrue(command.contains(#"/usr/bin/dscacheutil -flushcache"#))
        XCTAssertTrue(command.contains(#"if ! /usr/bin/dscacheutil -flushcache"#))
        XCTAssertTrue(command.contains(#"exit 1"#))

        let probe = GuestDNSConfigurator.probeCommand(for: config)
        XCTAssertTrue(probe.contains(#"if ! /usr/bin/dscacheutil -flushcache"#))
        XCTAssertTrue(
            probe.contains(
                #"/usr/bin/dig +time=5 +tries=1 +short "@$resolver""#
            )
        )
        XCTAssertTrue(probe.contains(#"for resolver in '1.1.1.1' '8.8.8.8'"#))
        XCTAssertTrue(
            probe.contains(
                #"-q host -a name 'broker.actions.githubusercontent.com'"#
            )
        )
        XCTAssertTrue(probe.contains(#"/usr/bin/grep -Eq '^ip_address: '"#))
        XCTAssertTrue(probe.contains(#"after network isolation"#))
    }

    func testQuotesNetworkServiceWithoutCommandInjection() {
        let config = Config.RunOptions.GuestDNS(
            networkService: #"Ethernet"; touch /tmp/pwned; echo "$(id)' "#,
            servers: ["1.1.1.1"],
            probeHost: #"broker.actions.githubusercontent.com"; touch /tmp/probe-pwned; echo "$(id)' "#
        )

        let command = GuestDNSConfigurator.configurationCommand(for: config)
        let probe = GuestDNSConfigurator.probeCommand(for: config)

        XCTAssertTrue(
            command.contains(
                #"'Ethernet"; touch /tmp/pwned; echo "$(id)'\'' '"#
            )
        )
        XCTAssertTrue(
            probe.contains(
                #"-a name 'broker.actions.githubusercontent.com"; touch /tmp/probe-pwned; echo "$(id)'\'' '"#
            )
        )
        XCTAssertFalse(command.contains(#"echo "Guest DNS configured for network service"#))
        XCTAssertFalse(command.contains(#"echo "guest DNS probe failed for"#))
    }
}
