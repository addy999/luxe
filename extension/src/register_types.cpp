/*
 * GDExtension registration entry points for the darktable-on-Godot PoC.
 *
 * The entry_symbol name (dt_backend_library_init) is fixed by
 * godot-poc/extension/dt_backend.gdextension's [configuration] section --
 * do not rename it without updating that file.
 *
 * Registers DtBackend, which links against darktable
 * (https://github.com/darktable-org/darktable), Copyright (C) the darktable
 * contributors, licensed under the GNU General Public License v3.0 or later.
 * See NOTICE for full attribution.
 */
#include "register_types.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "dt_backend.h"

using namespace godot;

void initialize_dt_backend_module(ModuleInitializationLevel p_level) {
  if(p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
    return;
  }

  GDREGISTER_CLASS(DtBackend);
}

void uninitialize_dt_backend_module(ModuleInitializationLevel p_level) {
  if(p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
    return;
  }
}

extern "C" {
// Initialization.
GDExtensionBool GDE_EXPORT dt_backend_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                                    GDExtensionClassLibraryPtr p_library,
                                                    GDExtensionInitialization *r_initialization) {
  godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

  init_obj.register_initializer(initialize_dt_backend_module);
  init_obj.register_terminator(uninitialize_dt_backend_module);
  init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

  return init_obj.init();
}
}
