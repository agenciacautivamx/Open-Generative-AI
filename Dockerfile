# Stage que clona los submodules directamente desde GitHub
# (Railway no clona submodules automaticamente)
FROM alpine/git AS submodules
WORKDIR /submodules
RUN git clone --depth 1 https://github.com/SamurAIGPT/Vibe-Workflow.git packages/Vibe-Workflow
RUN git clone --depth 1 https://github.com/Anil-matcha/Open-Poe-AI.git packages/Open-Poe-AI
RUN git clone --depth 1 https://github.com/Anil-matcha/Open-AI-Design-Agent.git packages/Open-AI-Design-Agent

FROM node:20-alpine AS base
WORKDIR /app

# Install dependencies
FROM base AS deps
COPY package*.json ./
COPY --from=submodules /submodules/packages/Vibe-Workflow/packages/workflow-builder/package*.json ./packages/Vibe-Workflow/packages/workflow-builder/
COPY --from=submodules /submodules/packages/Open-Poe-AI/packages/agents/package*.json ./packages/Open-Poe-AI/packages/agents/
COPY packages/studio/package*.json ./packages/studio/
RUN npm install

# Build sub-packages
FROM deps AS builder
COPY . .
COPY --from=submodules /submodules/packages/Vibe-Workflow ./packages/Vibe-Workflow
COPY --from=submodules /submodules/packages/Open-Poe-AI ./packages/Open-Poe-AI
COPY --from=submodules /submodules/packages/Open-AI-Design-Agent ./packages/Open-AI-Design-Agent
RUN npm run build:packages
RUN npm run build

# Production runner
FROM base AS runner
ENV NODE_ENV=production
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json

EXPOSE 3000
CMD ["npm", "start"]
