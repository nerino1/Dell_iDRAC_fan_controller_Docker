# Define global functions
# This function applies Dell's default dynamic fan control profile
function apply_Dell_default_fan_control_profile() {
  # Use ipmitool to send the raw command to set fan control to Dell default
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a user-specified static fan control profile
# Optional argument $1: decimal fan speed to use (defaults to $DECIMAL_FAN_SPEED)
function apply_user_fan_control_profile() {
  local TARGET_DECIMAL_SPEED="${1:-$DECIMAL_FAN_SPEED}"
  local TARGET_HEX_SPEED
  TARGET_HEX_SPEED=$(convert_decimal_value_to_hexadecimal "$TARGET_DECIMAL_SPEED")
  # Use ipmitool to send the raw command to set fan control to user-specified value
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $TARGET_HEX_SPEED > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($TARGET_DECIMAL_SPEED%)"
}

# Convert first parameter given ($DECIMAL_NUMBER) to hexadecimal
function convert_decimal_value_to_hexadecimal() {
  local -r DECIMAL_NUMBER=$1
  local -r HEXADECIMAL_NUMBER=$(printf '0x%02x' $DECIMAL_NUMBER)
  echo $HEXADECIMAL_NUMBER
}

# Convert first parameter given ($HEXADECIMAL_NUMBER) to decimal
function convert_hexadecimal_value_to_decimal() {
  local -r HEXADECIMAL_NUMBER=$1
  local -r DECIMAL_NUMBER=$(printf '%d' $HEXADECIMAL_NUMBER)
  echo $DECIMAL_NUMBER
}

# Set the IDRAC_LOGIN_STRING variable based on connection type
function set_iDRAC_login_string() {
  local IDRAC_HOST="$1"
  local IDRAC_USERNAME="$2"
  local IDRAC_PASSWORD="$3"

  IDRAC_LOGIN_STRING=""

  if [[ "$IDRAC_HOST" == "local" ]]; then
    if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
      print_error_and_exit "Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode"
    fi
    IDRAC_LOGIN_STRING='open'
  else
    echo "iDRAC/IPMI username: $IDRAC_USERNAME"
    IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
  fi
}

# Retrieve temperature sensors data using ipmitool
function retrieve_temperatures() {
  if (( $# != 2 )); then
    print_error "Illegal number of parameters.\nUsage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT \$IS_CPU2_TEMPERATURE_SENSOR_PRESENT"
    return 1
  fi
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1
  local -r IS_CPU2_TEMPERATURE_SENSOR_PRESENT=$2

  local -r DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature | grep degrees)

  # Parse CPU data
  local -r CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU1_TEMPERATURE_INDEX;}")
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
    CPU2_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU2_TEMPERATURE_INDEX;}")
    if ! [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]]; then
      CPU2_TEMPERATURE="-"
    fi
  else
    CPU2_TEMPERATURE="-"
  fi

  CPUS_TEMPERATURES="$CPU1_TEMPERATURE"
  NUMBER_OF_DETECTED_CPUS=1

  if [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]]; then
    CPUS_TEMPERATURES+=";$CPU2_TEMPERATURE"
    ((NUMBER_OF_DETECTED_CPUS++))
  fi

  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)

  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  else
    EXHAUST_TEMPERATURE="-"
  fi

  # Retrieve fan RPM data and calculate average
  local -r FAN_DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type Fan 2>/dev/null | grep RPM | grep -Po '\d{3,5} RPM' | grep -Po '\d+')
  if [ -n "$FAN_DATA" ]; then
    local FAN_TOTAL=0
    local FAN_COUNT=0
    while IFS= read -r rpm; do
      FAN_TOTAL=$(( FAN_TOTAL + rpm ))
      (( FAN_COUNT++ ))
    done <<< "$FAN_DATA"
    if [ "$FAN_COUNT" -gt 0 ]; then
      AVERAGE_FAN_RPM=$(( FAN_TOTAL / FAN_COUNT ))
    else
      AVERAGE_FAN_RPM=0
    fi
  else
    AVERAGE_FAN_RPM=0
  fi
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null
}

# Prepare traps in case of container exit
function graceful_exit() {
  apply_Dell_default_fan_control_profile

  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety"
}

function get_Dell_server_model() {
  local -r IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>/dev/null)

  SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | grep "Product Manufacturer" | awk -F ': ' '{print $2}')
  SERVER_MODEL=$(echo "$IPMI_FRU_content" | grep "Product Name" | awk -F ': ' '{print $2}')

  if [ -z "$SERVER_MANUFACTURER" ]; then
    SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Mfg :" | awk -F ': ' '{print $2}')
  fi

  if [ -z "$SERVER_MODEL" ]; then
    SERVER_MODEL=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Product :" | awk -F ': ' '{print $2}')
  fi
}

function build_header() {
  if [ "$#" -ne 1 ]; then
    print_error "build_header() requires an argument (number_of_CPUs)"
    return 1
  fi

  local -r number_of_CPUs="$1"
  local -r CPU_column_width=7
  local header="                     ----"

  number_of_dashes=$(((number_of_CPUs-1)*CPU_column_width/2))

  for ((i=1; i<=number_of_dashes; i++)); do
    header+="-"
  done

  header+=" Temperatures ---"

  if (( (number_of_CPUs - 1) * CPU_column_width % 2 != 0 )); then
    header+="-"
  fi

  for ((i=1; i<=number_of_dashes; i++)); do
    header+="-"
  done
  header+=$'\n    Date & time      Inlet  CPU 1 '

  for ((i=2; i<=number_of_CPUs; i++)); do
    header+=" CPU $i "
  done

  header+=$' Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment'
  printf "%s" "$header"
}

function print_temperature_array_line() {
  local -r LOCAL_INLET_TEMPERATURE="$1"
  local -r LOCAL_CPUS_TEMPERATURES="$2"
  local -r LOCAL_EXHAUST_TEMPERATURE="$3"
  local -r LOCAL_CURRENT_FAN_CONTROL_PROFILE="$4"
  local -r LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="$5"
  local -r LOCAL_COMMENT="$6"

  local -r CPUs_temperatures_array=(${LOCAL_CPUS_TEMPERATURES//;/ })

  printf "%19s  %3d°C " "$(date +"%d-%m-%Y %T")" $LOCAL_INLET_TEMPERATURE
  for temperature in "${CPUs_temperatures_array[@]}"; do
    if [[ "$temperature" == "-" ]]; then
      printf "   -°C "
    else
      printf " %3d°C " $temperature
    fi
  done

  printf " %5s°C  %40s  %51s  %s\n" "$LOCAL_EXHAUST_TEMPERATURE" "$LOCAL_CURRENT_FAN_CONTROL_PROFILE" "$LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$LOCAL_COMMENT"
}

# ---------------------------------------------------------------------------
# LOG TO CSV
# Appends a line to the CSV log file and prunes entries older than LOG_RETENTION_DAYS
# ---------------------------------------------------------------------------
function log_to_csv() {
  local -r TIMESTAMP="$(date +"%Y-%m-%d %T")"
  local -r LOG_FILE="${LOG_PATH:-/app/logs}/fan_controller.csv"
  local -r STATUS_FILE="${LOG_PATH:-/app/logs}/status.json"
  local -r RETENTION_DAYS="${LOG_RETENTION_DAYS:-365}"

  mkdir -p "$(dirname "$LOG_FILE")"
  if [ ! -f "$LOG_FILE" ]; then
    echo "timestamp,inlet_temp,cpu1_temp,cpu2_temp,exhaust_temp,fan_profile,fan_speed_pct,avg_fan_rpm" > "$LOG_FILE"
  fi

  local FAN_SPEED_PCT
  FAN_SPEED_PCT=$(echo "$CURRENT_FAN_CONTROL_PROFILE" | grep -Po '\d+(?=%)' | head -1)
  if [ -z "$FAN_SPEED_PCT" ]; then
    FAN_SPEED_PCT=100
  fi

  local CPU2_VAL="${CPU2_TEMPERATURE:-}"
  if ! [[ "$CPU2_VAL" =~ ^[0-9]+$ ]]; then CPU2_VAL=""; fi

  local EXHAUST_VAL="${EXHAUST_TEMPERATURE:-}"
  if ! [[ "$EXHAUST_VAL" =~ ^[0-9]+$ ]]; then EXHAUST_VAL=""; fi

  local RPM_VAL="${AVERAGE_FAN_RPM:-0}"

  # Check if override is active
  local OVERRIDE_ACTIVE="false"
  if [ -f "${LOG_PATH:-/app/logs}/fan_override" ]; then
    OVERRIDE_ACTIVE="true"
  fi

  echo "${TIMESTAMP},${INLET_TEMPERATURE},${CPU1_TEMPERATURE},${CPU2_VAL},${EXHAUST_VAL},${CURRENT_FAN_CONTROL_PROFILE},${FAN_SPEED_PCT},${RPM_VAL}" >> "$LOG_FILE"

  # Write current status JSON for dashboard plugin
  cat > "$STATUS_FILE" << JSONEOF
{
  "timestamp": "${TIMESTAMP}",
  "inlet_temp": ${INLET_TEMPERATURE},
  "cpu1_temp": ${CPU1_TEMPERATURE},
  "cpu2_temp": "${CPU2_VAL}",
  "exhaust_temp": "${EXHAUST_VAL}",
  "fan_profile": "${CURRENT_FAN_CONTROL_PROFILE}",
  "fan_speed_pct": ${FAN_SPEED_PCT},
  "avg_fan_rpm": ${RPM_VAL},
  "override_active": ${OVERRIDE_ACTIVE},
  "server_model": "${SERVER_MODEL:-}"
}
JSONEOF

  # Prune old entries
  local -r CUTOFF=$(date -d "-${RETENTION_DAYS} days" +"%Y-%m-%d %T" 2>/dev/null || date -v-${RETENTION_DAYS}d +"%Y-%m-%d %T")
  awk -v cutoff="$CUTOFF" 'NR==1 || $0 >= cutoff' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# STEPPED FAN CURVE
# ---------------------------------------------------------------------------
function apply_stepped_fan_curve() {
  local -r CPU_TEMP="$1"

  if [ "$CPU_TEMP" -ge "$CPU_TEMPERATURE_THRESHOLD" ]; then
    apply_Dell_default_fan_control_profile
  elif [ "$CPU_TEMP" -ge "$STEPPED_HIGH_TEMP" ]; then
    apply_user_fan_control_profile "$STEPPED_HIGH_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Stepped fan curve - High stage ($STEPPED_HIGH_FAN_SPEED% @ ${CPU_TEMP}°C)"
  elif [ "$CPU_TEMP" -ge "$STEPPED_MID_TEMP" ]; then
    apply_user_fan_control_profile "$STEPPED_MID_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Stepped fan curve - Mid stage ($STEPPED_MID_FAN_SPEED% @ ${CPU_TEMP}°C)"
  else
    apply_user_fan_control_profile "$DECIMAL_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Stepped fan curve - Low stage ($DECIMAL_FAN_SPEED% @ ${CPU_TEMP}°C)"
  fi
}

# ---------------------------------------------------------------------------
# LINEAR INTERPOLATION FAN CURVE
# ---------------------------------------------------------------------------
function apply_interpolated_fan_curve() {
  local -r CPU_TEMP="$1"

  if [ "$CPU_TEMP" -ge "$CPU_TEMPERATURE_THRESHOLD" ]; then
    apply_Dell_default_fan_control_profile
  elif [ "$CPU_TEMP" -ge "$INTERP_LOW_TEMP" ]; then
    local -r RANGE_TEMP=$(( INTERP_HIGH_TEMP - INTERP_LOW_TEMP ))
    local -r RANGE_SPEED=$(( INTERP_HIGH_FAN_SPEED - DECIMAL_FAN_SPEED ))
    local -r OFFSET=$(( CPU_TEMP - INTERP_LOW_TEMP ))
    local -r INTERPOLATED_SPEED=$(( DECIMAL_FAN_SPEED + (RANGE_SPEED * OFFSET * 100 / RANGE_TEMP + 50) / 100 ))
    apply_user_fan_control_profile "$INTERPOLATED_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Interpolated fan curve ($INTERPOLATED_SPEED% @ ${CPU_TEMP}°C)"
  else
    apply_user_fan_control_profile "$DECIMAL_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Interpolated fan curve - Min ($DECIMAL_FAN_SPEED% @ ${CPU_TEMP}°C)"
  fi
}

# ---------------------------------------------------------------------------
# OVERHEATING checks
# ---------------------------------------------------------------------------
function CPU1_OVERHEATING() { [ $CPU1_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }
function CPU2_OVERHEATING() { [ $CPU2_TEMPERATURE -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }

function print_error() {
  local -r ERROR_MESSAGE="$1"
  printf "/!\ Error /!\ %s." "$ERROR_MESSAGE" >&2
}

function print_error_and_exit() {
  local -r ERROR_MESSAGE="$1"
  print_error "$ERROR_MESSAGE"
  printf " Exiting.\n" >&2
  exit 1
}

function print_warning() {
  local -r WARNING_MESSAGE="$1"
  printf "/!\ Warning /!\ %s." "$WARNING_MESSAGE"
}

function print_warning_and_exit() {
  local -r WARNING_MESSAGE="$1"
  print_warning "$WARNING_MESSAGE"
  printf " Exiting.\n"
  exit 0
}
