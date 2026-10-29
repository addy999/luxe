class_name AndroidBootstrap

# Android-only startup helpers: unpack the bundled darktable data, ask for
# storage access, and list the default photo folders.

const DATA_ZIP: String = "res://bin/android_data/dt_data.zip"
const DATA_DIR: String = "user://dt_data"
const STAMP_PATH: String = "user://dt_data/.stamp"
const PHOTO_DIRS: PackedStringArray = ["/sdcard/Pictures", "/sdcard/DCIM"]


# Extracts DATA_ZIP into DATA_DIR (share/darktable/..., plugins.manifest) unless the
# stamp file already holds the zip's SHA-256. Returns false if the zip is missing or
# a file could not be written.
static func ensure_dt_data() -> bool:
	if not FileAccess.file_exists(DATA_ZIP):
		printerr("AndroidBootstrap: ", DATA_ZIP, " missing")
		return false
	var sha: String = FileAccess.get_sha256(DATA_ZIP)
	if FileAccess.file_exists(STAMP_PATH) and FileAccess.get_file_as_string(STAMP_PATH) == sha:
		return true
	# The APK stores assets deflated, so seeking inside res:// is quadratic; ZIPReader reads a local copy.
	var local_zip: String = ProjectSettings.globalize_path("user://dt_data.zip")
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(DATA_ZIP)
	var out: FileAccess = FileAccess.open(local_zip, FileAccess.WRITE)
	if out == null or bytes.is_empty():
		return false
	out.store_buffer(bytes)
	out.close()
	var zip: ZIPReader = ZIPReader.new()
	if zip.open(local_zip) != OK:
		return false
	var root: String = ProjectSettings.globalize_path(DATA_DIR)
	for entry: String in zip.get_files():
		if entry.ends_with("/"):
			continue
		var dst: String = root.path_join(entry)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			zip.close()
			return false
		f.store_buffer(zip.read_file(entry))
		f.close()
	zip.close()
	DirAccess.remove_absolute(local_zip)
	var stamp: FileAccess = FileAccess.open(STAMP_PATH, FileAccess.WRITE)
	stamp.store_string(sha)
	return true


# Requests the manifest-declared storage permissions (Godot also opens the
# all-files-access settings page when MANAGE_EXTERNAL_STORAGE is declared).
static func request_storage_permissions() -> void:
	OS.request_permissions()


# PHOTO_DIRS entries that exist on this device.
static func default_locations() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for dir_path: String in PHOTO_DIRS:
		if DirAccess.dir_exists_absolute(dir_path):
			result.append(dir_path)
	return result
