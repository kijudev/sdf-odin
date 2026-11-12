default: run

build:
    mkdir -p build
    odin build src -out:build/sdf -debug

run: build
    ./build/sdf
