FROM node:18-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY . .
# node:18-alpine ships a non-root "node" user (uid 1000) — use it instead of root.
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["npm", "start"]
