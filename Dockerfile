FROM nginxinc/nginx-unprivileged:1.31.2-alpine-slim@sha256:653c4c45a002a826b4c6c0902c7e21890ffdcae7c464866da79504c93d804f61

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

USER nginx

COPY static/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
