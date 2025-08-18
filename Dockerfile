FROM nimlang/nim:2.2.0-alpine AS builder
WORKDIR /app

# Copy package files
COPY rinha.nimble ./
RUN nimble install -y --depsOnly

# Copy source code
COPY . .
RUN nimble build -d:release --opt:speed --mm:orc

FROM alpine:latest AS runtime
RUN apk --no-cache add libc6-compat
COPY --from=builder /app/rinha /usr/local/bin/

ENTRYPOINT ["rinha"]
CMD []

EXPOSE 9999
