FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --legacy-peer-deps
COPY . .
RUN npm run build || echo "build skipped in dev"
EXPOSE 3000
CMD ["npm", "run", "start:dev"]
