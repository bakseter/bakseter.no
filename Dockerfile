FROM nginxinc/nginx-unprivileged:1.31.2-alpine-slim@sha256:ee7751c78fd1a51a8c12ac5a0ab15b2de2d486df155ef95bf52db9cef7de0d2d

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

USER nginx

COPY static/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
