FROM node:22-alpine
WORKDIR /app
COPY package.json server.mjs ./
EXPOSE 3000
USER node
CMD ["node", "server.mjs"]
