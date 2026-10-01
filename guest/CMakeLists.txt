cmake_minimum_required(VERSION 3.16)
project(telemetry_guest C CXX)

# Laid out as the pen's guests are: the sandbox guest API's cmake helper, a stage ELF installed
# into the Godot project, and the riscv64 sysroot through the toolchain file tools/build.exs passes.
get_filename_component(OTEL_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(SANDBOX_API_ROOT "${OTEL_ROOT}/third_party/sandbox-api" CACHE PATH "The godot-sandbox guest API")
set(PROTOBUF_ROOT "${OTEL_ROOT}/third_party/protobuf" CACHE PATH "protocolbuffers/protobuf at v36.2")
set(OTLP_GEN "${OTEL_ROOT}/gen/otlp" CACHE PATH "protoc --upb_out and --upb_minitable_out of the OTLP protos")
set(ELF_NAME "telemetry" CACHE STRING "Installed as PROJECT_DIR/ELF_NAME.elf")
set(PROJECT_DIR "${OTEL_ROOT}/project" CACHE PATH "The Godot project the ELF is installed into")

add_compile_options("-ffile-prefix-map=${OTEL_ROOT}/=")

set(DOWNLOAD_RUNTIME_API OFF CACHE BOOL "" FORCE)
add_subdirectory(${SANDBOX_API_ROOT}/cmake sandbox_api)

# upb's C runtime, only what the generated setters and serialize link against.
set(UPB ${PROTOBUF_ROOT}/upb)
add_library(upb_runtime STATIC
	${UPB}/hash/common.c
	${UPB}/mem/alloc.c
	${UPB}/mem/arena.c
	${UPB}/message/array.c
	${UPB}/message/internal/extension.c
	${UPB}/message/internal/message.c
	${UPB}/message/map.c
	${UPB}/message/map_sorter.c
	${UPB}/message/message.c
	${UPB}/message/unknown_fields.c
	${UPB}/wire/encode.c
	${UPB}/wire/eps_copy_input_stream.c
	${UPB}/wire/internal/back_alloc.c
	${UPB}/wire/internal/encoder.c
	${UPB}/wire/reader.c
)
target_include_directories(upb_runtime PUBLIC ${PROTOBUF_ROOT})
target_link_libraries(upb_runtime PUBLIC sandbox_api)

file(GLOB_RECURSE OTLP_MINITABLES CONFIGURE_DEPENDS ${OTLP_GEN}/*.upb_minitable.c)
add_library(otlp_messages STATIC ${OTLP_MINITABLES})
target_include_directories(otlp_messages PUBLIC ${OTLP_GEN})
target_link_libraries(otlp_messages PUBLIC upb_runtime)

function(add_stage_elf name)
	add_sandbox_program(${name} ${ARGN})
	target_link_libraries(${name} PRIVATE -lm -lstdc++)
	add_custom_command(TARGET ${name} POST_BUILD
		COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:${name}> ${PROJECT_DIR}/${ELF_NAME}.elf
		COMMENT "Installing ${ELF_NAME}.elf"
	)
endfunction()

add_stage_elf(telemetry ${CMAKE_CURRENT_SOURCE_DIR}/main.cpp ${CMAKE_CURRENT_SOURCE_DIR}/telemetry.cpp)
target_link_libraries(telemetry PRIVATE otlp_messages upb_runtime)
