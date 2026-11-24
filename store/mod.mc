// store — JSON load/save/merge for TaskStore (idiomatic %C).
import "model";
import "json";
import "fs";
import "os";
import "path";
import "str";

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "host_time.h"

enum {
	BackupKeep = 5,
	BackupMinAgeSec = 3600,
	/* at most one new generation per hour */
	BackupPathCap = 1100
};

/* path.bak.N into dst; false if it would not fit. */
static bool backup_slot_path(char[..] dst, const char[..] path, int n) {
	char suf[16] = { 0 };
	if (ptr(dst) == NULL || cap(dst) == 0 || n < 1) {
		return false;
	}
	snprintf(suf, sizeof(suf), ".bak.%d", n);
	size_t need = len(path) + strlen(suf) + 1;
	if (need > cap(dst)) {
		return false;
	}
	snprintf(ptr(dst), cap(dst), "%.*s%s", (int)len(path), ptr(path), suf);
	return true;
}

/* True when we should mint a new bak.1 from the live file. */
static bool backup_due(const char[..] path) {
	char bak1[BackupPathCap] = { 0 };
	if (!backup_slot_path(ranged(bak1, sizeof(bak1)), path, 1)) {
		return false;
	}
	auto (info, ok) = fs_stat(ranged(bak1, strlen(bak1)));
	if (!ok || info.kind != KindFile) {
		return true;
	}
	int64_t now = time(NULL);
	if (now <= 0 || info.mtime_ns <= 0) {
		return true;
	}
	/* mtime_ns is wall-clock ns since epoch. */
	return now - (info.mtime_ns / 1000000000L) >= BackupMinAgeSec;
}

static const char[..] obj_str(const JsonValue* obj, const char* key) {
	if (obj == NULL || key == NULL) {
		return str_from_cstr("");
	}
	const JsonValue* v = json_object_get(obj, key);
	const char* s = json_string_value(v);
	return str_from_cstr(s != NULL ? s: "");
}

[[nodiscard]](char[..], bool) store_default_path([[region]] Pool * p) {
	auto (env_ok, env) = os_env("MFDB");
	if (p == NULL) {
		return (str_empty(), false);
	}
	if (env_ok && len(env) > 0) {
		char[..] out = { 0 };
		if (!p.append(&out, env)) {
			return (str_empty(), false);
		}
		return (out, true);
	}
	auto (cfg, cok) = os_user_config_dir(p);
	if (!cok) {
		return (str_empty(), false);
	}
	auto (dir, dok) = path_join(p, cfg, "modfocus");
	if (!dok) {
		return (str_empty(), false);
	}
	return path_join(p, dir, "tasks.json");
}

[[nodiscard]] bool store_ensure_parent_dir(const char[..] db_path) {
	const char[..] parent = path_dir(db_path);
	if (len(parent) == 0) {
		return true;
	}
	auto (info, ok) = fs_stat(parent);
	if (ok && info.kind == KindDir) {
		return true;
	}
	return fs_mkdir(parent);
}

static(char[..], bool) read_file_all(const char[..] path) {
	auto (r, ok) = reader_open(path, OpenRead, 0);
	char[..] data = str_empty();
	if (!ok) {
		return (str_empty(), false);
	}
	defer r.close();
	for (;;) {
		char chunk[8192] = { 0 };
		auto (n, rok) = r.read(ranged(chunk, sizeof(chunk)));
		if (!rok) {
			str_free(&data);
			return (str_empty(), false);
		}
		if (n == 0) {
			break;
		}
		if (!str_append(&data, ranged(chunk, (size_t)n))) {
			str_free(&data);
			return (str_empty(), false);
		}
	}
	return (data, true);
}

static bool copy_file(const char[..] from, const char[..] to) {
	auto (data, ok) = read_file_all(from);
	if (!ok) {
		return false;
	}
	defer str_free(&data);
	auto (w, wok) = writer_open(to, OpenWrite | OpenCreate | OpenTrunc, 0);
	if (!wok) {
		return false;
	}
	defer w.close();
	auto (n, wok2) = w.write(data);
	if (!wok2 || n != (int64_t)len(data)) {
		return false;
	}
	return w.flush();
}

/*
 * Rotate path.bak.(N-1) → path.bak.N, then copy live → path.bak.1.
 * Live file stays in place so a crash cannot leave the DB missing.
 * Best-effort: failure must not block the subsequent atomic replace.
 */
static void store_rotate_backups(const char[..] path) {
	char older[BackupPathCap] = { 0 };
	char newer[BackupPathCap] = { 0 };
	auto (live, lok) = fs_stat(path);
	if (!lok || live.kind != KindFile) {
		return;
	}
	if (!backup_due(path)) {
		return;
	}
	for (int i = BackupKeep; i >= 2; i--) {
		if (!backup_slot_path(ranged(older, sizeof(older)), path, i) || !backup_slot_path(ranged(newer, sizeof(newer)), path, i - 1)) {
			return;
		}
		(void)fs_remove(ranged(older, strlen(older)));
		auto (prev, pok) = fs_stat(ranged(newer, strlen(newer)));
		if (pok && prev.kind == KindFile) {
			(void)fs_rename(ranged(newer, strlen(newer)), ranged(older, strlen(older)));
		}
	}
	if (!backup_slot_path(ranged(newer, sizeof(newer)), path, 1)) {
		return;
	}
	(void)fs_remove(ranged(newer, strlen(newer)));
	(void)copy_file(path, ranged(newer, strlen(newer)));
}

/*
 * If path is missing but path.bak.1 exists, copy bak → path.
 * True when the primary exists afterward (already or recovered).
 */
[[nodiscard]] bool store_recover_primary(const char[..] path) {
	char bak1[BackupPathCap] = { 0 };
	auto (info, ok) = fs_stat(path);
	if (ok && info.kind == KindFile) {
		return true;
	}
	if (!backup_slot_path(ranged(bak1, sizeof(bak1)), path, 1)) {
		return false;
	}
	auto (b, bok) = fs_stat(ranged(bak1, strlen(bak1)));
	if (!bok || b.kind != KindFile) {
		return false;
	}
	return copy_file(ranged(bak1, strlen(bak1)), path);
}

/* True when path exists as a regular file. */
[[nodiscard]] bool store_path_is_file(const char[..] path) {
	auto (info, ok) = fs_stat(path);
	return ok && info.kind == KindFile;
}

/*
 * Load tasks from path. False on I/O, parse, schema, or capacity errors —
 * the store is left empty. Callers must use store_path_is_file to tell a
 * missing DB (create empty) from a corrupt one (refuse to overwrite).
 */
[[nodiscard]] bool (TaskStore* store).load(const char[..] path) {
	JsonError err = { 0 };
	store.init();
	auto (text, tok) = read_file_all(path);
	if (!tok) {
		return false;
	}
	defer str_free(&text);
	JsonValue* root = json_parse_n(ptr(text), len(text), &err);
	if (root == NULL) {
		return false;
	}
	defer json_free(root);
	if (root.type != JSON_OBJECT) {
		return false;
	}
	const JsonValue* tasks = json_object_get(root, "tasks");
	if (tasks == NULL || tasks.type != JSON_ARRAY) {
		return false;
	}
	for (size_t i = 0; i < json_array_size(tasks); i++) {
		const JsonValue* item = json_array_get(tasks, i);
		Task t = { 0 };
		if (item == NULL || item.type != JSON_OBJECT) {
			continue;
		}
		(void)str_set(&t.id, obj_str(item, "id"));
		(void)str_set(&t.status, obj_str(item, "status"));
		(void)str_set(&t.title, obj_str(item, "title"));
		(void)str_set(&t.cc, obj_str(item, "cc"));
		(void)str_set(&t.tags, obj_str(item, "tags"));
		(void)str_set(&t.updated, obj_str(item, "updated"));
		if (len(t.title) == 0 && len(t.id) == 0) {
			t.clear();
			continue;
		}
		if (!store.add(&t)) {
			t.clear();
			store.init();
			return false;
		}
		t.clear();
		/* add deep-copied; drop temps */
	}
	/* Optional tombstones[] — older files omit it. */
	{
		const JsonValue* tombs = json_object_get(root, "tombstones");
		if (tombs != NULL && tombs.type == JSON_ARRAY) {
			for (size_t i = 0; i < json_array_size(tombs); i++) {
				const JsonValue* item = json_array_get(tombs, i);
				const char[..] id = { 0 };
				const char[..] deleted = { 0 };
				if (item == NULL || item.type != JSON_OBJECT) {
					continue;
				}
				id = obj_str(item, "id");
				deleted = obj_str(item, "deleted");
				if (len(id) == 0) {
					continue;
				}
				if (!store.tomb_put(id, deleted)) {
					store.init();
					return false;
				}
			}
			/* Drop any loaded task still covered by a tombstone. */
			for (int i = store.count - 1; i >= 0; i--) {
				if (store.tomb_blocks(store.tasks[i].id, store.tasks[i].updated)) {
					if (!store.remove(i)) {
						store.init();
						return false;
					}
				}
			}
		}
	}
	store.dirty = false;
	store.sort();
	return true;
}

[[nodiscard]] bool (TaskStore* store).save(const char[..] path) {
	if (!store_ensure_parent_dir(path)) {
		return false;
	}
	store.tomb_prune();
	JsonValue* root = json_new_object();
	if (root == NULL) {
		return false;
	}
	defer json_free(root);
	if (!json_object_set(root, "version", json_new_number(1))) {
		return false;
	}
	JsonValue* arr = json_new_array();
	if (arr == NULL) {
		return false;
	}
	if (!json_object_set(root, "tasks", arr)) {
		return false;
	}
	arr = json_object_get_mutable(root, "tasks");
	for (int i = 0; i < store.count; i++) {
		Task* t = &store.tasks[i];
		JsonValue* obj = json_new_object();
		if (obj == NULL) {
			return false;
		}
		if (!json_object_set(obj, "id", json_new_string_n(ptr(t.id), len(t.id))) || !json_object_set(obj, "status", json_new_string_n(ptr(t.status), len(t.status))) || !json_object_set(obj, "title", json_new_string_n(ptr(t.title), len(t.title))) || !json_object_set(obj, "cc", json_new_string_n(ptr(t.cc), len(t.cc))) || !json_object_set(obj, "tags", json_new_string_n(ptr(t.tags), len(t.tags))) || !json_object_set(obj, "updated", json_new_string_n(ptr(t.updated), len(t.updated)))) {
			json_free(obj);
			return false;
		}
		if (!json_array_append(arr, obj)) {
			return false;
		}
	}
	if (store.tomb_count > 0) {
		JsonValue* tarr = json_new_array();
		if (tarr == NULL) {
			return false;
		}
		if (!json_object_set(root, "tombstones", tarr)) {
			return false;
		}
		tarr = json_object_get_mutable(root, "tombstones");
		for (int i = 0; i < store.tomb_count; i++) {
			Tombstone* t = &store.tombs[i];
			JsonValue* obj = json_new_object();
			if (obj == NULL) {
				return false;
			}
			if (!json_object_set(obj, "id", json_new_string_n(ptr(t.id), len(t.id))) ||
				!json_object_set(obj, "deleted", json_new_string_n(ptr(t.deleted), len(t.deleted)))) {
				json_free(obj);
				return false;
			}
			if (!json_array_append(tarr, obj)) {
				return false;
			}
		}
	}
	char* text = json_stringify(root);
	if (text == NULL) {
		return false;
	}
	defer free(text);
	pool p {
		char[..] tmp_path = { 0 };
		if (!p.append(&tmp_path, path) || !p.append(&tmp_path, ".tmp")) {
			return false;
		}
		{
			auto (w, wok) = writer_open(tmp_path, OpenWrite | OpenCreate | OpenTrunc, 0);
			if (!wok) {
				return false;
			}
			defer w.close();
			const char[..] body = str_from_cstr(text);
			auto (n, ok) = w.write(body);
			if (!ok || n != (int64_t)len(body)) {
				return false;
			}
			if (!w.flush()) {
				return false;
			}
		}
		/* Copy-based backup while live still exists, then atomic replace. */
		store_rotate_backups(path);
		if (!fs_rename(tmp_path, path)) {
			(void)fs_remove(tmp_path);
			return false;
		}
	}
	store.dirty = false;
	return true;
}

[[nodiscard]] bool store_import_file(TaskStore* store, const char[..] src, const char[..] dst) {
	static TaskStore seed;
	if (store == NULL) {
		return false;
	}
	seed.init();
	if (!seed.load(src)) {
		return false;
	}
	(void)store_recover_primary(dst);
	if (!store.load(dst)) {
		if (store_path_is_file(dst)) {
			/* Corrupt destination — do not clobber. */
			return false;
		}
		store.init();
	}
	(void)store.merge(&seed);
	store.dirty = true;
	return store.save(dst);
}

static int store_find_id(const TaskStore* store, const char[..] id) {
	if (store == NULL || len(id) == 0) {
		return -1;
	}
	for (int i = 0; i < store.count; i++) {
		if (str_eq(store.tasks[i].id, id)) {
			return i;
		}
	}
	return -1;
}

static int updated_cmp(const char[..] a, const char[..] b) {
	if (len(a) == 0 && len(b) == 0) {
		return 0;
	}
	if (len(a) == 0) {
		return -1;
	}
	if (len(b) == 0) {
		return 1;
	}
	return str_cmp(a, b);
}

[[nodiscard]] bool (TaskStore* local).merge(const TaskStore* incoming) {
	bool changed = false;
	if (incoming == NULL) {
		return false;
	}
	/* Merge tombstones first (LWW by deleted stamp); drop blocked local tasks. */
	for (int i = 0; i < incoming.tomb_count; i++) {
		const Tombstone* src = &incoming.tombs[i];
		int ti = -1;
		int at = -1;
		if (len(src.id) == 0) {
			continue;
		}
		ti = -1;
		for (int j = 0; j < local.tomb_count; j++) {
			if (str_eq(local.tombs[j].id, src.id)) {
				ti = j;
				break;
			}
		}
		if (ti >= 0 && updated_cmp(src.deleted, local.tombs[ti].deleted) <= 0) {
			continue;
		}
		if (!local.tomb_put(src.id, src.deleted)) {
			break;
		}
		changed = true;
		at = store_find_id(local, src.id);
		if (at >= 0 && local.tomb_blocks(src.id, local.tasks[at].updated)) {
			if (!local.remove(at)) {
				break;
			}
		}
	}
	for (int i = 0; i < incoming.count; i++) {
		const Task* src = &incoming.tasks[i];
		int at = store_find_id(local, src.id);
		if (local.tomb_blocks(src.id, src.updated)) {
			continue;
		}
		if (at < 0) {
			if (!local.add(src)) {
				break;
			}
			changed = true;
			continue;
		}
		if (updated_cmp(src.updated, local.tasks[at].updated) > 0) {
			if (!local.replace(at, src)) {
				break;
			}
			changed = true;
		}
	}
	return changed;
}
