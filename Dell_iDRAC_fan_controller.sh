#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# ---------------------------------------------------------------------------
# FAN CONTROL MODE
# Set FAN_CONTROL_MODE to one of:
#   standard    - original single-threshold behaviour (default)
#   stepped     - 3-stage stepped curve
#   interpolate - smooth linear ramp between two temp points
# ---------------------------------------------------------------------------
FAN_CONTROL_MODE="${FAN_CONTROL_MODE:-standard}"

# ---------------------------------------------------------------------------
# Validate and convert FAN_SPEED (baseline / minimum speed)
# ---------------------------------------------------------------------------
if [[ "$FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  readonly HEXADECIMAL_FAN_SPEED="$FAN_SPEED"
else
  readonly DECIMAL_FAN_SPEED="$FAN_SPEED"
  readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

# ---------------------------------------------------------------------------
# Validate mode-specific env vars
# ---------------------------------------------------------------------------
if [[ "$FAN_CONTROL_MODE" == "stepped" ]]; then
  : "${STEPPED_MID_TEMP:?  ERROR: STEPPED_MID_TEMP must be set for stepped mode}"
  : "${STEPPED_MID_FAN_SPEED:?  ERROR: STEPPED_MID_FAN_SPEED must be set for stepped mode}"
  : "${STEPPED_HIGH_TEMP:?  ERROR: STEPPED_HIGH_TEMP must be set for stepped mode}"
  : "${STEPPED_HIGH_FAN_SPEED:?  ERROR: STEPPED_HIGH_FAN_SPEED must be set for stepped mode}"
fi

if [[ "$FAN_CONTROL_MODE" == "interpolate" ]]; then
  : "${INTERP_LOW_TEMP:?  ERROR: INTERP_LOW_TEMP must be set for interpolate mode}"
  : "${INTERP_HIGH_TEMP:?  ERROR: INTERP_HIGH_TEMP must be set for interpolate mode}"
  : "${INTERP_HIGH_FAN_SPEED:?  ERROR: INTERP_HIGH_FAN_SPEED must be set for interpolate mode}"
fi

# ---------------------------------------------------------------------------
# Connect to iDRAC
# ---------------------------------------------------------------------------
set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# If server model is Gen 14 (*40) or newer
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=true
  readonly CPU1_TEMPERATURE_INDEX=2
  readonly CPU2_TEMPERATURE_INDEX=4
else
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=false
  readonly CPU1_TEMPERATURE_INDEX=1
  readonly CPU2_TEMPERATURE_INDEX=2
fi

# ---------------------------------------------------------------------------
# Startup log
# ---------------------------------------------------------------------------
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"
echo "Fan control mode: $FAN_CONTROL_MODE"

case "$FAN_CONTROL_MODE" in
  stepped)
    echo "  Baseline fan speed : $DECIMAL_FAN_SPEED%"
    echo "  Mid stage          : >= ${STEPPED_MID_TEMP}C -> ${STEPPED_MID_FAN_SPEED}%"
    echo "  High stage         : >= ${STEPPED_HIGH_TEMP}C -> ${STEPPED_HIGH_FAN_SPEED}%"
    echo "  Dell hand-back     : >= ${CPU_TEMPERATURE_THRESHOLD}C"
    ;;
  interpolate)
    echo "  Minimum fan speed  : $DECIMAL_FAN_SPEED% (below ${INTERP_LOW_TEMP}C)"
    echo "  Ramp start         : ${INTERP_LOW_TEMP}C"
    echo "  Ramp end / max     : ${INTERP_HIGH_TEMP}C -> ${INTERP_HIGH_FAN_SPEED}%"
    echo "  Dell hand-back     : >= ${CPU_TEMPERATURE_THRESHOLD}C"
    ;;
  *)
    echo "  Fan speed objective       : $DECIMAL_FAN_SPEED%"
    echo "  CPU temperature threshold : ${CPU_TEMPERATURE_THRESHOLD}C"
    ;;
esac

echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

# ---------------------------------------------------------------------------
# Initialise state
# ---------------------------------------------------------------------------
TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true

# Start first timer in background
sleep "$CHECK_INTERVAL" &
SLEEP_PROCESS_PID=$!

retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT

if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
if [ -z "$CPU2_TEMPERATURE" ]; then
  echo "No CPU2 temperature sensor detected."
  IS_CPU2_TEMPERATURE_SENSOR_PRESENT=false
fi
if ! $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT || ! $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
  echo ""
fi

readonly HEADER=$(build_header $NUMBER_OF_DETECTED_CPUS)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do
  COMMENT=" -"

  # Pick the highest CPU temperature to drive the fan curve decisions
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && [ "$CPU2_TEMPERATURE" != "-" ]; then
    if [ "$CPU2_TEMPERATURE" -gt "$CPU1_TEMPERATURE" ]; then
      MAX_CPU_TEMPERATURE=$CPU2_TEMPERATURE
    else
      MAX_CPU_TEMPERATURE=$CPU1_TEMPERATURE
    fi
  else
    MAX_CPU_TEMPERATURE=$CPU1_TEMPERATURE
  fi

  case "$FAN_CONTROL_MODE" in
    stepped)
      apply_stepped_fan_curve "$MAX_CPU_TEMPERATURE"
      if [[ "$CURRENT_FAN_CONTROL_PROFILE" == "Dell default dynamic fan control profile" ]]; then
        if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
          COMMENT="CPU temp >= ${CPU_TEMPERATURE_THRESHOLD}C, Dell default fan control applied for safety"
        fi
      else
        if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
          COMMENT="CPU temp back within range, stepped fan curve active"
        fi
      fi
      ;;

    interpolate)
      apply_interpolated_fan_curve "$MAX_CPU_TEMPERATURE"
      if [[ "$CURRENT_FAN_CONTROL_PROFILE" == "Dell default dynamic fan control profile" ]]; then
        if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
          COMMENT="CPU temp >= ${CPU_TEMPERATURE_THRESHOLD}C, Dell default fan control applied for safety"
        fi
      else
        if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
          COMMENT="CPU temp back within range, interpolated fan curve active"
        fi
      fi
      ;;

    *)
      # Original standard mode — unchanged behaviour
      if CPU1_OVERHEATING; then
        apply_Dell_default_fan_control_profile
        if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
          if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
            COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
          else
            COMMENT="CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
          fi
        fi
      elif $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
        apply_Dell_default_fan_control_profile
        if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
          COMMENT="CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
        fi
      else
        apply_user_fan_control_profile
        if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
          IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
          COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD C), user's fan control profile applied."
        fi
      fi
      ;;
  esac

  # PCIe cooling response (Gen 13 and older only)
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER; then
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      disable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
    fi
  fi

  # Print table header every N lines
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))

  wait $SLEEP_PROCESS_PID

  # Start next timer
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
done
