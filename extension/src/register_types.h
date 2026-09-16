/*
 * GDExtension registration entry points for the darktable-on-Godot PoC.
 * Mirrors the standard godot-cpp boilerplate (see
 * godot-poc/extension/godot-cpp/test/src/register_types.h for the reference
 * this was checked against).
 */
#pragma once

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_dt_backend_module(ModuleInitializationLevel p_level);
void uninitialize_dt_backend_module(ModuleInitializationLevel p_level);
