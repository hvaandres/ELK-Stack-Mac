# SOC Lab Elasticsearch image.
# Thin layer over the official image that bakes in the lab's static config so
# the running container is reproducible from this repo alone.
ARG STACK_VERSION=9.5.5
FROM docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}

LABEL org.opencontainers.image.title="soc-lab-elasticsearch" \
      org.opencontainers.image.description="Elasticsearch for the SOC Lab Part 3 centralized monitoring platform"

COPY --chown=elasticsearch:root elasticsearch.yml /usr/share/elasticsearch/config/elasticsearch.yml
