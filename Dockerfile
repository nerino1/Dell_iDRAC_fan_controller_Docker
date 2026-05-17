FROM ubuntu:latest
LABEL org.opencontainers.image.authors="tigerblue77"
RUN apt-get update
RUN apt-get install ipmitool python3 -y
ADD functions.sh /app/functions.sh
ADD constants.sh /app/constants.sh
ADD healthcheck.sh /app/healthcheck.sh
ADD Dell_iDRAC_fan_controller.sh /app/Dell_iDRAC_fan_controller.sh
RUN chmod 0777 /app/functions.sh /app/healthcheck.sh /app/Dell_iDRAC_fan_controller.sh
RUN mkdir -p /app/logs
WORKDIR /app
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 CMD [ "/app/healthcheck.sh" ]
ENV IDRAC_HOST=local
ENV FAN_SPEED=5
ENV CPU_TEMPERATURE_THRESHOLD=50
ENV CHECK_INTERVAL=60
ENV FAN_CONTROL_MODE=standard
ENV WEBUI_ENABLED=true
ENV WEBUI_PORT=8080
ENV LOG_PATH=/app/logs
ENV LOG_RETENTION_DAYS=365
ENV DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
ENV KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
ENTRYPOINT ["./Dell_iDRAC_fan_controller.sh"]
