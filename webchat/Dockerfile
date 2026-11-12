FROM oven/bun:1.3.6-alpine AS build
WORKDIR /app
COPY webchat/package.json webchat/bun.lock ./
RUN bun install --frozen-lockfile
COPY webchat/ .
ARG VITE_PARENT_ORIGINS=https://alo.ne
ARG VITE_DASHBOARD_URL=https://alo.ne
ENV VITE_PARENT_ORIGINS=$VITE_PARENT_ORIGINS VITE_DASHBOARD_URL=$VITE_DASHBOARD_URL
RUN bun run build

FROM nginx:1.27-alpine
COPY webchat/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html/web
COPY legal /usr/share/nginx/html/legal
COPY check /usr/share/nginx/html/check
COPY site /usr/share/nginx/html/legal
COPY site /usr/share/nginx/html/check
COPY public /usr/share/nginx/html/public
COPY site /usr/share/nginx/html/public
EXPOSE 8087
