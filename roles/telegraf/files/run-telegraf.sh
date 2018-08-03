#!/usr/bin/env bash
set -euo pipefail

# Note: This script works assumes that the non-configurable defaults setup by the Ansible roles
# and the `core` and `vault-ssh` modules are not changed. Otherwise, it will fail to
# find the right values and will not work.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"

readonly MAX_RETRIES=30
readonly SLEEP_BETWEEN_RETRIES_SEC=10

function print_usage {
  echo
  echo "Usage: run-telegraf [OPTIONS]"
  echo
  echo "This script is used to configure Telegraf on an AWS server."
  echo
  echo "Options:"
  echo
  echo -e "  --type\t\tThe type of instance being configured. Required. Keys must exist in Consul for the server type"
  echo -e "  --consul-prefix\t\tPath prefix in Consul KV store to query for integration status. Optional. Defaults to terraform/"
  echo -e "  --consul-template-config\t\tPath to directory of configuration files for Consul Template. Optional. Defaults to `/opt/consul-template/config`"
  echo
  echo "Example:"
  echo
  echo "  run-telegraf --type consul"
}

function log {
  local readonly level="$1"
  local readonly message="$2"
  local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local readonly message="$1"
  log "INFO" "${message}"
}

function log_warn {
  local readonly message="$1"
  log "WARN" "${message}"
}

function log_error {
  local readonly message="$1"
  log "ERROR" "${message}"
}

function assert_not_empty {
  local readonly arg_name="$1"
  local readonly arg_value="$2"

  if [[ -z "${arg_value}" ]]; then
    log_error "The value for '${arg_name}' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    log_error "The binary '${name}' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function wait_for_consul {
  local consul_leader

  for (( i=1; i<="$MAX_RETRIES"; i++ )); do
    consul_leader=$(
      curl -sS http://localhost:8500/v1/status/leader 2> /dev/null || echo "failed"
    )

    if [[ "${consul_leader}" = "failed" ]]; then
      log_warn "Failed to find Consul cluster leader. Will sleep for $SLEEP_BETWEEN_RETRIES_SEC seconds and try again."
      sleep "$SLEEP_BETWEEN_RETRIES_SEC"
    else
      log_info "Found Consul leader at ${consul_leader}"
      return
    fi
  done

  log_error "Failed to detect Consul agent after $MAX_RETRIES retries. Did you start a Consul agent before running the script?"
  exit 1
}

function consul_kv {
  local readonly path="${1}"
  local value
  value=$(consul kv get "${path}") || exit $?
  log_info "Consul KV Path ${path} = ${value}"
  echo -n "${value}"
}

function consul_kv_with_default {
  local readonly path="${1}"
  local readonly default="${2}"
  local value
  value=$(consul kv get "${path}" || echo -n "${default}") || exit $?
  log_info "Consul KV Path ${path} = ${value}"
  echo -n "${value}"
}

function enable_telegraf {
  local readonly type="${1}"
  local readonly service_override_dir="${2}"

  log_info "Enabling and starting service telegraf for type $type..."

  mkdir -p "$service_override_dir"
  echo -e "[Service]\nEnvironment=SERVER_TYPE=$type" > "$service_override_dir/override.conf"

  systemctl enable telegraf
  systemctl start telegraf

  log_info "Service telegraf enabled and started!"
}

function enable_elasticsearch {
  local readonly elasticsearch_service="${1}"
  local readonly consul_template_config="${2}"
  local readonly config_override_dir="${3}"

  local readonly destination="${config_override_dir}/output_elasticsearch.conf"
  local readonly template_destination="${consul_template_config}/template_telegraf_output_elasticsearch.hcl"

  local template=$(cat <<EOF
template {
  destination = "${destination}"
  command = "service telegraf restart"
  left_delimiter  = "||"
  right_delimiter = "||"

  contents = <<EOT
###############################################################################
#                            OUTPUT PLUGINS                                   #
###############################################################################

# Configuration for Elasticsearch to send metrics to.
[[outputs.elasticsearch]]
  ## The full HTTP endpoint URL for your Elasticsearch instance
  ## Multiple urls can be specified as part of the same cluster,
  ## this means that only ONE of the urls will be written to each interval.
  urls = [
    || range service "${elasticsearch_service}" ||"https://|| .Address ||:|| .Port ||", || end ||
  ] # required.
  ## Elasticsearch client timeout, defaults to "5s" if not set.
  timeout = "5s"
  ## Set to true to ask Elasticsearch a list of all cluster nodes,
  ## thus it is not necessary to list all nodes in the urls config option.
  enable_sniffer = false
  ## Set the interval to check if the Elasticsearch nodes are available
  ## Setting to "0s" will disable the health check (not recommended in production)
  health_check_interval = "10s"
  ## HTTP basic authentication details (eg. when using Shield)
  # username = "telegraf"
  # password = "mypassword"

  ## Index Config
  ## The target index for metrics (Elasticsearch will create if it not exists).
  ## You can use the date specifiers below to create indexes per time frame.
  ## The metric timestamp will be used to decide the destination index name
  # %Y - year (2016)
  # %y - last two digits of year (00..99)
  # %m - month (01..12)
  # %d - day of month (e.g., 01)
  # %H - hour (00..23)
  # %V - week of the year (ISO week) (01..53)
  ## Additionally, you can specify a tag name using the notation {{tag_name}}
  ## which will be used as part of the index name. If the tag does not exist,
  ## the default tag value will be used.
  index_name = "metrics.{{_server_type}}-%Y.%m.%d"
  default_tag_value = "metrics.unknown-%Y.%m.%d"

  ## Optional SSL Config
  # ssl_ca = "/etc/telegraf/ca.pem"
  # ssl_cert = "/etc/telegraf/cert.pem"
  # ssl_key = "/etc/telegraf/key.pem"
  ## Use SSL but skip chain & host verification
  # insecure_skip_verify = false

  ## Template Config
  ## Set to true if you want telegraf to manage its index template.
  ## If enabled it will create a recommended index template for telegraf indexes
  manage_template = true
  ## The template name used for telegraf indexes
  template_name = "telegraf"
  ## Set to true if you want telegraf to overwrite an existing template
  overwrite_template = true

EOT
}
EOF
)

  log_info "Writing Consul Template configuration to ${template_destination}"
  echo -n "${template}" > "${template_destination}"
}

function main {
  local type=""
  local consul_prefix="terraform/"
  local consul_template_config="/opt/consul-template/config"

  local readonly service_override_dir="/etc/systemd/system/telegraf.service.d"
  local readonly config_override_dir="/etc/telegraf/telegraf.d"

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      --type)
        assert_not_empty "$key" "$2"
        type="$2"
        shift
        ;;
      --consul-prefix)
        assert_not_empty "$key" "$2"
        consul_prefix="$2"
        shift
        ;;
      --consul-template-config)
        assert_not_empty "$key" "$2"
        consul_template_config="$2"
        shift
        ;;
      --help)
        print_usage
        exit
        ;;
      *)
        log_error "Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  if [[ -z "${type}" ]]; then
    log_error "You must specify the --type"
    exit 1
  fi

  assert_is_installed "consul"

  wait_for_consul

  local readonly enabled=$(consul_kv_with_default "${consul_prefix}telegraf/server_types/${type}/enabled" "no")

  if [[ "$enabled" != "yes" ]]; then
    log_info "Telegraf is not enabled for ${type}"
  else
    enable_telegraf "$type" "$service_override_dir"

    local readonly elasticsearch=$(consul_kv_with_default "${consul_prefix}telegraf/server_types/${type}/output/elasticsearch/enabled" "no")

    if [[ "$elasticsearch" == "yes" ]]; then
      assert_is_installed "consul-template"
      local readonly elasticsearch_service=$(consul_kv "${consul_prefix}telegraf/server_types/${type}/output/elasticsearch/service_name")

      log_info "Configuring Telegraf to output to Elasticsearch at service name '${elasticsearch_service}'"

      enable_elasticsearch "${elasticsearch_service}" "${consul_template_config}" "${config_override_dir}"
      supervisorctl signal SIGHUP consul-template
    fi
  fi
}

main "$@"
