FROM node:26.13.0-alpine@sha256:8996bb5821d62a8fd9bb27c1cb07462f3fdce6e47d640c6a881ead0b064ce216 AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY eleventy.config.js ./
COPY src/ ./src/
RUN npm run build


FROM nginx/nginx-unprivileged:1.31.8-alpine-otel@sha256:e4e539cb008fa24160ae55b7807c1e3aff7619f7ce1f8cc88eee8978714ca837

USER root

RUN mkdir -p /tmp/nginx && \
    chown -R nginx:nginx /tmp/nginx

USER nginx

COPY --from=build /app/_site/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
