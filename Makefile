BIN    := raptor
PREFIX := $(HOME)/.local

.PHONY: build install clean

build:
	go build -o $(BIN) .

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)
