BIN  := davbox
ADDR ?= 0.0.0.0:18900
DATA ?= ./data

.PHONY: build frontend run test vet clean

# 前端构建产物会被 go:embed 打进二进制，所以必须先构建前端。
frontend:
	cd web && npm install && npm run build

build: frontend
	go build -o $(BIN) ./cmd/davbox

run: build
	./$(BIN) -addr $(ADDR) -data $(DATA)

vet:
	go vet ./...

test: vet
	go test ./...

clean:
	rm -f $(BIN)
	rm -rf web/dist
