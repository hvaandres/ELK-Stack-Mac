# SOC Lab Kibana image.
ARG STACK_VERSION=9.5.5
FROM docker.elastic.co/kibana/kibana:${STACK_VERSION}

LABEL org.opencontainers.image.title="soc-lab-kibana" \
      org.opencontainers.image.description="Kibana for the SOC Lab Part 3 centralized monitoring platform"

COPY --chown=kibana:root kibana.yml /usr/share/kibana/config/kibana.yml
