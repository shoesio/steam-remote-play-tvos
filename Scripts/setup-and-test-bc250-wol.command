#!/bin/bash
set -euo pipefail

HOST="${1:-jhewes@192.168.0.125}"
MAC="${2:-a8:a1:59:b5:e9:6d}"

echo "BC-250 Wake-on-LAN setup"
echo "Host: ${HOST}"
echo "Expected MAC: ${MAC}"
echo
echo "SSH and sudo may each ask for the BC-250 password."
echo

remote_payload="$(base64 <<'REMOTE' | tr -d '\n'
set -euo pipefail

normalize_mac() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

target_mac="$(normalize_mac "${TARGET_MAC}")"
iface=""
for address_file in /sys/class/net/*/address; do
    candidate="$(cat "${address_file}")"
    if [[ "$(normalize_mac "${candidate}")" == "${target_mac}" ]]; then
        iface="$(basename "$(dirname "${address_file}")")"
        break
    fi
done

if [[ -z "${iface}" ]]; then
    iface="$(ip route show default | awk 'NR == 1 { print $5 }')"
fi
if [[ -z "${iface}" || ! -d "/sys/class/net/${iface}" ]]; then
    echo "Could not identify the BC-250 network interface." >&2
    exit 1
fi

actual_mac="$(cat "/sys/class/net/${iface}/address")"
connection="$(nmcli -g GENERAL.CONNECTION device show "${iface}" | head -1)"

echo "Detected interface: ${iface}"
echo "Detected MAC:       ${actual_mac}"
echo "NetworkManager:     ${connection:-<no active connection>}"
echo

if ! command -v ethtool >/dev/null 2>&1; then
    echo "ethtool is not installed, so NIC Wake-on-LAN cannot be inspected." >&2
    exit 1
fi

echo "Current NIC support and state:"
sudo ethtool "${iface}" | sed -n '/Supports Wake-on:/p;/Wake-on:/p'
echo
echo "Driver:"
sudo ethtool -i "${iface}" | sed -n '1,6p'
echo

supports="$(sudo ethtool "${iface}" | awk -F': ' '/Supports Wake-on:/ { print $2 }')"
if [[ "${supports}" != *g* ]]; then
    echo "This NIC/driver does not advertise magic-packet Wake-on-LAN support." >&2
    exit 2
fi

echo "Enabling magic-packet wake now..."
sudo ethtool -s "${iface}" wol g

if [[ -n "${connection}" && "${connection}" != "--" ]]; then
    echo "Persisting Wake-on-LAN in NetworkManager..."
    sudo nmcli connection modify "${connection}" 802-3-ethernet.wake-on-lan magic
fi

wakeup_file="/sys/class/net/${iface}/device/power/wakeup"
if [[ -f "${wakeup_file}" ]]; then
    wakeup_state="$(cat "${wakeup_file}")"
    if [[ "${wakeup_state}" != "enabled" ]]; then
        echo "Enabling PCI wake permission..."
        printf 'enabled\n' | sudo tee "${wakeup_file}" >/dev/null
    fi
fi

echo
echo "Final Wake-on-LAN state:"
sudo ethtool "${iface}" | sed -n '/Supports Wake-on:/p;/Wake-on:/p'
if [[ -n "${connection}" && "${connection}" != "--" ]]; then
    nmcli -g 802-3-ethernet.wake-on-lan connection show "${connection}" || true
fi
if [[ -f "${wakeup_file}" ]]; then
    printf 'PCI wake: '
    cat "${wakeup_file}"
fi
printf 'Sleep modes: '
cat /sys/power/mem_sleep 2>/dev/null || echo "unavailable"
echo
echo "Host-side Wake-on-LAN configuration complete."
REMOTE
)"

ssh -tt "${HOST}" "printf '%s' '${remote_payload}' | base64 -d | env TARGET_MAC='${MAC}' bash"

echo
read -r -p "Suspend the BC-250 now and send a real wake test? [y/N] " answer
case "${answer}" in
    y|Y|yes|YES)
        echo "Suspending ${HOST}..."
        ssh -tt "${HOST}" 'sudo systemctl suspend' || true
        echo "Waiting for the NIC to enter its suspended wake state..."
        sleep 12

        echo "Sending repeated magic packets to ${MAC}..."
        MAC_FOR_WOL="${MAC}" perl -MIO::Socket::INET -e '
            my $mac = $ENV{"MAC_FOR_WOL"};
            $mac =~ s/[^0-9A-Fa-f]//g;
            die "Invalid MAC address\n" unless length($mac) == 12;
            my $packet = pack("H*", "ff" x 6 . $mac x 16);
            for my $host ("255.255.255.255", "192.168.0.255") {
                for my $port (9, 47009, 47998, 47999, 48000, 48002, 48010) {
                    my $socket = IO::Socket::INET->new(
                        PeerAddr => $host,
                        PeerPort => $port,
                        Proto => "udp",
                        Broadcast => 1
                    );
                    $socket->send($packet) if $socket;
                    close($socket) if $socket;
                }
            }
        '

        echo "Waiting up to 60 seconds for the BC-250..."
        awake=0
        for _ in $(seq 1 30); do
            if nc -z -w 1 192.168.0.125 22 >/dev/null 2>&1; then
                awake=1
                break
            fi
            sleep 2
            MAC_FOR_WOL="${MAC}" perl -MIO::Socket::INET -e '
                my $mac = $ENV{"MAC_FOR_WOL"}; $mac =~ s/[^0-9A-Fa-f]//g;
                my $packet = pack("H*", "ff" x 6 . $mac x 16);
                my $s = IO::Socket::INET->new(PeerAddr=>"255.255.255.255", PeerPort=>9, Proto=>"udp", Broadcast=>1);
                $s->send($packet) if $s; close($s) if $s;
            '
        done

        if [[ "${awake}" == 1 ]]; then
            echo "SUCCESS: the BC-250 woke and SSH is reachable."
        else
            echo "FAILED: the host-side settings look correct, but the BC-250 did not wake."
            echo "That usually points to BIOS/firmware ErP, PCIe wake, or power-state support."
            exit 3
        fi
        ;;
    *)
        echo "Skipped the live suspend/wake test."
        ;;
esac

echo
read -r -p "Press Return to close this terminal..." _
