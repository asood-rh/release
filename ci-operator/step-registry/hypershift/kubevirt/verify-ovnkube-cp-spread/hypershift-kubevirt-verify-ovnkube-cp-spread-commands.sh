#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# KUBECONFIG already points at the management cluster: ci-operator exports
# ${SHARED_DIR}/kubeconfig for every step, and nothing here repoints it at the
# guest. The hosted control plane, including ovnkube-control-plane, lives in
# the management cluster's hosted control plane namespace.

MCE=${MCE_VERSION:-""}
CLUSTER_NAME="$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
if [[ -n ${MCE} ]]; then
  CLUSTER_NAMESPACE_PREFIX=local-cluster
else
  CLUSTER_NAMESPACE_PREFIX=clusters
fi
CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}

replicas=$(oc get deployment ovnkube-control-plane -n "${CLUSTER_NAMESPACE}" -o jsonpath='{.spec.replicas}')
echo "ovnkube-control-plane in ${CLUSTER_NAMESPACE} has ${replicas} replica(s)"

if [[ "${replicas}" -le 1 ]]; then
  echo "CNO renders the anti-affinity only above one replica, so there is nothing to verify here."
  echo "Set CONTROL_PLANE_AVAILABILITY=HighlyAvailable for this check to mean anything."
  exit 0
fi

# The assertion. A required zone anti-affinity cannot be satisfied when every
# management node carries the same topology.kubernetes.io/zone value, so on a
# single-zone cluster the second replica stays Pending and this times out.
# Diagnostics are guarded so a failure always reports why rather than aborting
# on the first dump.
if ! oc rollout status deployment/ovnkube-control-plane -n "${CLUSTER_NAMESPACE}" --timeout="${OVNKUBE_CP_ROLLOUT_TIMEOUT}"; then
  echo "ERROR: ovnkube-control-plane did not roll out within ${OVNKUBE_CP_ROLLOUT_TIMEOUT}"
  echo "An unsatisfiable anti-affinity appears below as a Pending pod whose scheduler"
  echo "event reads \"didn't match pod anti-affinity rules\"."
  oc get pods -n "${CLUSTER_NAMESPACE}" -l app=ovnkube-control-plane -o wide || true
  oc describe pods -n "${CLUSTER_NAMESPACE}" -l app=ovnkube-control-plane | sed -n '/^Events:/,$p' || true
  oc get nodes -L topology.kubernetes.io/zone || true
  exit 1
fi

# Relaxing the zone rule must not let the replicas share a node: the required
# hostname rule is what still guarantees node-level spreading.
nodes=$(oc get pods -n "${CLUSTER_NAMESPACE}" -l app=ovnkube-control-plane \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
node_count=$(echo "${nodes}" | awk 'NF' | wc -l)

if [[ "${node_count}" -lt "${replicas}" ]]; then
  echo "ERROR: ${replicas} ovnkube-control-plane replicas occupy only ${node_count} node(s);"
  echo "the required hostname anti-affinity is not holding."
  oc get pods -n "${CLUSTER_NAMESPACE}" -l app=ovnkube-control-plane -o wide || true
  exit 1
fi

# Zones are reported, not asserted: on a single-zone management cluster every
# replica shares a zone and that is the expected outcome.
while read -r node; do
  zone=$(oc get node "${node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  echo "  replica on ${node} (zone ${zone:-<unlabelled>})"
done <<< "${nodes}"

echo "ovnkube-control-plane: ${replicas} replicas on ${node_count} distinct node(s)"
