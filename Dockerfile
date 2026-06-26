FROM peaceiris/mdbook:v0.5.0 AS build

RUN apk add --no-cache bash jq

WORKDIR /app

COPY book.toml ./
COPY tools ./tools
COPY src ./src

ARG SECODER_BASE_DOMAIN=t.secoder.net
ENV SECODER_BASE_DOMAIN=${SECODER_BASE_DOMAIN}

RUN mdbook build

FROM nginx:alpine AS runtime

COPY --from=build /app/book /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
