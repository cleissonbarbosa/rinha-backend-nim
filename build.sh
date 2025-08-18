#!/bin/bash

# Script de build para o projeto Rinha Backend Nim

set -e

# Configuration
IMAGE_NAME="rinha-backend-nim"
VERSION=${1:-"latest"}
TIMESTAMP_VERSION=$(date +"%Y%m%d-%H%M%S")
DOCKER_HUB_USERNAME=${DOCKER_HUB_USERNAME:-""}
GITHUB_USERNAME=${GITHUB_USERNAME:-"cleissonbarbosa"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function push_to_dockerhub() {
    if [ -z "$DOCKER_HUB_USERNAME" ]; then
        read -p "Enter your Docker Hub username: " DOCKER_HUB_USERNAME
    fi
    
    local hub_image="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$VERSION"
    local hub_image_timestamp="$DOCKER_HUB_USERNAME/$IMAGE_NAME:$TIMESTAMP_VERSION"
    
    echo -e "${BLUE}🏷️  Tagging image for Docker Hub: $hub_image${NC}"
    docker tag ${IMAGE_NAME}:${VERSION} $hub_image
    
    echo -e "${BLUE}🏷️  Tagging image with timestamp for Docker Hub: $hub_image_timestamp${NC}"
    docker tag ${IMAGE_NAME}:${VERSION} $hub_image_timestamp
    
    echo -e "${BLUE}📤 Pushing to Docker Hub...${NC}"
    if docker push $hub_image && docker push $hub_image_timestamp; then
        echo -e "${GREEN}✅ Successfully pushed to Docker Hub: $hub_image${NC}"
        echo -e "${GREEN}✅ Successfully pushed to Docker Hub: $hub_image_timestamp${NC}"
        echo -e "${BLUE}💡 To use this image: docker pull $hub_image${NC}"
        echo -e "${BLUE}💡 Or with timestamp: docker pull $hub_image_timestamp${NC}"
    else
        echo -e "${RED}❌ Failed to push to Docker Hub. Make sure you're logged in: docker login${NC}"
    fi
}

function push_to_github() {
    local github_image="ghcr.io/$GITHUB_USERNAME/$IMAGE_NAME:$VERSION"
    local github_image_timestamp="ghcr.io/$GITHUB_USERNAME/$IMAGE_NAME:$TIMESTAMP_VERSION"
    
    echo -e "${BLUE}🏷️  Tagging image for GitHub Registry: $github_image${NC}"
    docker tag ${IMAGE_NAME}:${VERSION} $github_image
    
    echo -e "${BLUE}🏷️  Tagging image with timestamp for GitHub Registry: $github_image_timestamp${NC}"
    docker tag ${IMAGE_NAME}:${VERSION} $github_image_timestamp
    
    echo -e "${BLUE}📤 Pushing to GitHub Container Registry...${NC}"
    if docker push $github_image && docker push $github_image_timestamp; then
        echo -e "${GREEN}✅ Successfully pushed to GitHub Registry: $github_image${NC}"
        echo -e "${GREEN}✅ Successfully pushed to GitHub Registry: $github_image_timestamp${NC}"
        echo -e "${BLUE}💡 To use this image: docker pull $github_image${NC}"
        echo -e "${BLUE}💡 Or with timestamp: docker pull $github_image_timestamp${NC}"
    else
        echo -e "${RED}❌ Failed to push to GitHub Registry. Make sure you're logged in: echo \$GITHUB_TOKEN | docker login ghcr.io -u $GITHUB_USERNAME --password-stdin${NC}"
    fi
}

function start_services_locally() {
    echo -e "${BLUE}🚀 Starting services locally...${NC}"
    docker-compose up -d
    
    echo -e "${GREEN}✅ Services started!${NC}"
    echo -e "${BLUE}📊 Application available at: http://localhost:9999${NC}"
    echo -e "${BLUE}🏥 Health check: http://localhost:9999/health${NC}"
    
    # Wait a moment and check health
    sleep 3
    echo -e "${BLUE}🔍 Checking health...${NC}"
    if curl -f http://localhost:9999/health > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Application is healthy!${NC}"
    else
        echo -e "${YELLOW}⚠️  Application might still be starting up...${NC}"
    fi
}

echo -e "${BLUE}🐳 Building Rinha Backend Nim Docker image...${NC}"
echo -e "${BLUE}📅 Build timestamp: $TIMESTAMP_VERSION${NC}"

# Build da imagem
docker build --no-cache -t ${IMAGE_NAME}:${VERSION} .

# Create timestamp version tag
echo -e "${BLUE}🏷️  Creating timestamp tag: ${IMAGE_NAME}:${TIMESTAMP_VERSION}${NC}"
docker tag ${IMAGE_NAME}:${VERSION} ${IMAGE_NAME}:${TIMESTAMP_VERSION}

echo -e "${GREEN}✅ Build completed successfully!${NC}"
echo -e "${GREEN}✅ Created tags: ${IMAGE_NAME}:${VERSION} and ${IMAGE_NAME}:${TIMESTAMP_VERSION}${NC}"

# Ask for push options
echo -e "${YELLOW}📦 Push options:${NC}"
echo "1) Docker Hub"
echo "2) GitHub Container Registry (ghcr.io)"
echo "3) Both registries"
echo "4) Skip push"
echo "5) Start services locally"

read -p "Choose an option (1-5): " -n 1 -r
echo

case $REPLY in
    1)
        echo -e "${BLUE}🚀 Pushing to Docker Hub...${NC}"
        push_to_dockerhub
        ;;
    2)
        echo -e "${BLUE}🚀 Pushing to GitHub Container Registry...${NC}"
        push_to_github
        ;;
    3)
        echo -e "${BLUE}🚀 Pushing to both registries...${NC}"
        push_to_dockerhub
        push_to_github
        ;;
    4)
        echo -e "${YELLOW}⏭️  Skipping push...${NC}"
        ;;
    5)
        start_services_locally
        ;;
    *)
        echo -e "${YELLOW}⏭️  Invalid option, skipping push...${NC}"
        ;;
esac

echo -e "${GREEN}🎉 Script completed!${NC}"
