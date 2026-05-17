#!/bin/bash
# set -euo pipefail

source functions.sh
source constants.sh

trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# ---------------------------------------------------------------------------
# FAN CONTROL MODE: standard | stepped | interpolate
# ---------------------------------------------------------------------------
FAN_CONTROL_MODE="${FAN_CONTROL_MODE:-standard}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_PATH="${LOG_PATH:-/app/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-365}"

# ---------------------------------------------------------------------------
# Web UI
# ---------------------------------------------------------------------------
WEBUI_PORT="${WEBUI_PORT:-8080}"
WEBUI_ENABLED="${WEBUI_ENABLED:-true}"

# ---------------------------------------------------------------------------
# Validate and convert FAN_SPEED
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
# Start web UI server
# ---------------------------------------------------------------------------
if [[ "$WEBUI_ENABLED" == "true" ]]; then
  mkdir -p "$LOG_PATH"
  # Write the web UI HTML file
  cat > "$LOG_PATH/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>iDRAC Fan Controller</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f1117; color: #e2e8f0; min-height: 100vh; }
  header { background: #1a1d2e; border-bottom: 1px solid #2d3748; padding: 16px 24px; display: flex; align-items: center; gap: 12px; }
  header h1 { font-size: 1.2rem; font-weight: 600; color: #63b3ed; }
  header span { font-size: 0.8rem; color: #718096; }
  .controls { padding: 16px 24px; display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .btn { padding: 6px 16px; border-radius: 6px; border: 1px solid #2d3748; background: #1a1d2e; color: #a0aec0; cursor: pointer; font-size: 0.85rem; transition: all 0.15s; }
  .btn:hover { border-color: #63b3ed; color: #63b3ed; }
  .btn.active { background: #2b4a7a; border-color: #63b3ed; color: #63b3ed; }
  .status { margin-left: auto; font-size: 0.8rem; color: #718096; }
  .status.ok { color: #68d391; }
  .status.error { color: #fc8181; }
  .charts { padding: 0 24px 24px; display: grid; gap: 20px; }
  .chart-card { background: #1a1d2e; border: 1px solid #2d3748; border-radius: 10px; padding: 20px; }
  .chart-card h2 { font-size: 0.9rem; font-weight: 500; color: #a0aec0; margin-bottom: 16px; text-transform: uppercase; letter-spacing: 0.05em; }
  canvas { max-height: 220px; }
  .stats { padding: 0 24px 20px; display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
  .stat { background: #1a1d2e; border: 1px solid #2d3748; border-radius: 8px; padding: 14px 16px; }
  .stat .label { font-size: 0.75rem; color: #718096; margin-bottom: 4px; }
  .stat .value { font-size: 1.5rem; font-weight: 600; color: #e2e8f0; }
  .stat .unit { font-size: 0.8rem; color: #718096; }
</style>
</head>
<body>
<header>
  <h1>🖥 iDRAC Fan Controller</h1>
  <span id="server-name">Loading...</span>
</header>
<div class="controls">
  <button class="btn active" onclick="setRange('1d')">24h</button>
  <button class="btn" onclick="setRange('7d')">7 days</button>
  <button class="btn" onclick="setRange('30d')">30 days</button>
  <button class="btn" onclick="setRange('365d')">1 year</button>
  <span class="status" id="status">Loading...</span>
</div>
<div class="stats">
  <div class="stat"><div class="label">Inlet Temp</div><div class="value" id="s-inlet">--</div><div class="unit">°C</div></div>
  <div class="stat"><div class="label">CPU Temp</div><div class="value" id="s-cpu">--</div><div class="unit">°C</div></div>
  <div class="stat"><div class="label">Exhaust Temp</div><div class="value" id="s-exhaust">--</div><div class="unit">°C</div></div>
  <div class="stat"><div class="label">Fan Speed</div><div class="value" id="s-fan">--</div><div class="unit">%</div></div>
  <div class="stat"><div class="label">Last Updated</div><div class="value" style="font-size:0.9rem" id="s-time">--</div><div class="unit">&nbsp;</div></div>
</div>
<div class="charts">
  <div class="chart-card"><h2>Temperatures</h2><canvas id="tempChart"></canvas></div>
  <div class="chart-card"><h2>Fan Speed %</h2><canvas id="fanChart"></canvas></div>
</div>
<script>
let currentRange = '1d';
let tempChart, fanChart;
let allData = [];

const CHART_DEFAULTS = {
  responsive: true,
  maintainAspectRatio: true,
  animation: false,
  plugins: { legend: { labels: { color: '#a0aec0', boxWidth: 12, font: { size: 11 } } }, tooltip: { mode: 'index', intersect: false } },
  scales: {
    x: { type: 'time', ticks: { color: '#718096', maxTicksLimit: 8 }, grid: { color: '#2d3748' } },
    y: { ticks: { color: '#718096' }, grid: { color: '#2d3748' } }
  }
};

function setRange(r) {
  currentRange = r;
  document.querySelectorAll('.btn').forEach(b => b.classList.remove('active'));
  event.target.classList.add('active');
  renderCharts();
}

function filterData(data, range) {
  const now = new Date();
  const ms = { '1d': 86400000, '7d': 604800000, '30d': 2592000000, '365d': 31536000000 };
  const cutoff = new Date(now - ms[range]);
  return data.filter(r => new Date(r.ts) >= cutoff);
}

function renderCharts() {
  const data = filterData(allData, currentRange);
  if (!data.length) return;

  const labels = data.map(r => new Date(r.ts));
  const inlet = data.map(r => r.inlet);
  const cpu1 = data.map(r => r.cpu1);
  const exhaust = data.map(r => r.exhaust !== '' ? +r.exhaust : null);
  const fan = data.map(r => +r.fan);

  // Update stats from latest reading
  const last = data[data.length - 1];
  document.getElementById('s-inlet').textContent = last.inlet;
  document.getElementById('s-cpu').textContent = last.cpu1;
  document.getElementById('s-exhaust').textContent = last.exhaust || '--';
  document.getElementById('s-fan').textContent = last.fan === '100' ? 'Dell' : last.fan;
  document.getElementById('s-time').textContent = last.ts.substring(11, 16);

  const tempData = {
    labels,
    datasets: [
      { label: 'CPU 1', data: cpu1, borderColor: '#fc8181', backgroundColor: 'rgba(252,129,129,0.1)', tension: 0.3, pointRadius: 0, fill: true },
      { label: 'Inlet', data: inlet, borderColor: '#63b3ed', backgroundColor: 'rgba(99,179,237,0.1)', tension: 0.3, pointRadius: 0, fill: true },
      { label: 'Exhaust', data: exhaust, borderColor: '#f6ad55', backgroundColor: 'rgba(246,173,85,0.1)', tension: 0.3, pointRadius: 0, fill: true, spanGaps: true }
    ]
  };

  const fanData = {
    labels,
    datasets: [{ label: 'Fan Speed %', data: fan, borderColor: '#68d391', backgroundColor: 'rgba(104,211,145,0.15)', tension: 0.3, pointRadius: 0, fill: true }]
  };

  if (tempChart) tempChart.destroy();
  if (fanChart) fanChart.destroy();

  tempChart = new Chart(document.getElementById('tempChart'), { type: 'line', data: tempData, options: { ...CHART_DEFAULTS, scales: { ...CHART_DEFAULTS.scales, y: { ...CHART_DEFAULTS.scales.y, title: { display: true, text: '°C', color: '#718096' } } } } });
  fanChart = new Chart(document.getElementById('fanChart'), { type: 'line', data: fanData, options: { ...CHART_DEFAULTS, scales: { ...CHART_DEFAULTS.scales, y: { ...CHART_DEFAULTS.scales.y, min: 0, max: 105, title: { display: true, text: '%', color: '#718096' } } } } });
}

async function loadData() {
  try {
    const res = await fetch('fan_controller.csv');
    if (!res.ok) throw new Error('CSV not found');
    const text = await res.text();
    const lines = text.trim().split('\n');
    // header: timestamp,inlet_temp,cpu1_temp,cpu2_temp,exhaust_temp,fan_profile,fan_speed_pct
    allData = lines.slice(1).map(line => {
      const [ts, inlet, cpu1, cpu2, exhaust, profile, fan] = line.split(',');
      return { ts, inlet, cpu1, cpu2, exhaust, profile, fan };
    }).filter(r => r.ts);
    document.getElementById('status').textContent = `${allData.length} readings`;
    document.getElementById('status').className = 'status ok';
    if (allData.length) {
      document.getElementById('server-name').textContent = 'Dell PowerEdge';
    }
    renderCharts();
  } catch(e) {
    document.getElementById('status').textContent = 'Error loading data: ' + e.message;
    document.getElementById('status').className = 'status error';
  }
}

loadData();
setInterval(loadData, 60000);
</script>
</body>
</html>
HTML

  # Start Python HTTP server serving the logs directory
  cd "$LOG_PATH" && python3 -m http.server "$WEBUI_PORT" --bind 0.0.0.0 > /dev/null 2>&1 &
  WEBUI_PID=$!
  echo "Web UI started on port $WEBUI_PORT (PID $WEBUI_PID)"
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
echo "Log path: ${LOG_PATH}/fan_controller.csv (retention: ${LOG_RETENTION_DAYS} days)"
echo ""

# ---------------------------------------------------------------------------
# Initialise state
# ---------------------------------------------------------------------------
TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true

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

  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]]; then
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

  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER; then
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      disable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
    fi
  fi

  # Log to CSV
  log_to_csv

  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))

  wait $SLEEP_PROCESS_PID

  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
done
