# Points kubectl at the app host's k3s, for the current shell:
#
#   source scripts/k3s-env.sh
#   k get pods                  # kubectl in the lembos namespace
#   lembos-admin-password       # the bootstrap administrator's password
#
# The kubeconfig is the one the app host writes when the cluster becomes ready. The namespace is an alias rather
# than the context's default, because the app host rewrites that file on every start.

_lembos_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export KUBECONFIG="$_lembos_root/aspire/Lembos.Deploy.AppHost/.k3s/k3s/local/kubeconfig.yaml"
unset _lembos_root

alias k='kubectl --namespace lembos'

lembos-admin-password() {
    kubectl --namespace lembos get secret lembos-secrets -o jsonpath='{.data.identity-admin-password}' | base64 -d
    echo
}
