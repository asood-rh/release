#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

QUERY=".[0].ip"
if [ "${ipv6_enabled:-}" == "true" ]; then
 QUERY=".[0].ipv6"
fi
RENDEZVOUS_IP="$(yq -r e -o=j -I=0 "${QUERY}" "${SHARED_DIR}/hosts.yaml")"
# Create an agent-config file containing only the minimum required configuration

ntp_host=$(< "${CLUSTER_PROFILE_DIR}/aux-host-internal-name")
cat > "${SHARED_DIR}/agent-config-unconfigured.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${ntp_host}
EOF

cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${ntp_host}
hosts: []
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not create host config for additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
    # on a single-arch payload migrated to a multi-arch cluster)
    continue
  fi
  ADAPTED_YAML="
  hostname: ${name}
  role: ${name%%-[0-9]*}
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  interfaces:
  - macAddress: ${mac}
    name: ${baremetal_iface}
  networkConfig:
    interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: ${ipv4_enabled}
        dhcp: ${ipv4_enabled}
      ipv6:
        enabled: ${ipv6_enabled}
        dhcp: ${ipv6_enabled}
        auto-gateway: ${ipv6_enabled}
        auto-routes: ${ipv6_enabled}
        autoconf: ${ipv6_enabled}
        auto-dns: ${ipv6_enabled}
"

# Workaround: Comment out this code until OCPBUGS-34849 is fixed
#  # split the ipi_disabled_ifaces semi-comma separated list into an array
#  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
#  for iface in "${ipi_disabled_ifaces[@]}"; do
#    # Take care of the indentation when adding the disabled interfaces to the above yaml
#    ADAPTED_YAML+="
#    - name: ${iface}
#      type: ethernet
#      state: up
#      ipv4:
#        enabled: false
#        dhcp: false
#      ipv6:
#        enabled: false
#        dhcp: false
#    "
#  done
  # Patch the agent-config.yaml by adding the given host to the hosts list in the platform.baremetal stanza
  yq --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
    "$SHARED_DIR/agent-config.yaml" - <<< "$ADAPTED_YAML"
done
