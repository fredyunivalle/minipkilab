FROM nginx:alpine
COPY nginx/nginx.conf /etc/nginx/nginx.conf
RUN mkdir -p /etc/nginx/tls
COPY server/server.crt /etc/nginx/tls/server.crt
COPY server/server.key /etc/nginx/tls/server.key
