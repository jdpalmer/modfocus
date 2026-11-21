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
	BackupMinAgeSec = 3600, /* at most one new generation per hour */
	BackupPathCap = 1100
};

/* path.bak.N into dst; false if it would not fit. */
static bool backup_slot_path(char[..] dst, const char[..] path, int n) {
	char suf[16] = {0};
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
	char bak1[BackupPathCap] = {0};
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

/*
 * Rotate path.bak.(N-1) → path.bak.N, then path → path.bak.1.
 * Best-effort: failure must not block the subsequent save.
 */
static void store_rotate_backups(const char[..] path) {
	char older[BackupPathCap] = {0};
	char newer[BackupPathCap] = {0};
	auto (live, lok) = fs_stat(path);
	if (!lok || live.kind != KindFile) {
		return;
	}
	if (!backup_due(path)) {
		return;
	}
	for (int i = BackupKeep; i >= 2; i--) {
		if (!backup_slot_path(ranged(older, sizeof(older)), path, i) ||
			!backup_slot_path(ranged(newer, sizeof(newer)), path, i - 1)) {
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
	(void)fs_rename(path, ranged(newer, strlen(newer)));
}

static const char[..] obj_str(const JsonValue *obj, const char *key) {
	if (obj == NULL || key == NULL) {
		return str_from_cstr("");
	}
	const JsonValue *v = json_object_get(obj, key);
	const char *s = json_string_value(v);
	return str_from_cstr(s != NULL ? s : "");
}

bool store_default_path(char[..] dst) {
	auto (env_ok, env) = os_env("MFDB");
	if (ptr(dst) == NULL || cap(dst) == 0) {
		return false;
	}
	if (env_ok && len(env) > 0) {
		(void)cstr_write(dst, env);
		return true;
	}
	pool p {
		auto (cfg, cok) = os_user_config_dir(&p);
		if (!cok) {
			return false;
		}
		auto (dir, dok) = path_join(&p, cfg, "modfocus");
		if (!dok) {
			return false;
		}
		auto (file, fok) = path_join(&p, dir, "tasks.json");
		if (!fok) {
			return false;
		}
		(void)cstr_write(dst, file);
		return true;
	}
}

bool store_ensure_parent_dir(const char[..] db_path) {
	const char[..] parent = path_dir(db_path);
	if (len(parent) == 0) {
		return true;
	}
	(void)fs_mkdir(parent);
	return true;
}

static (char[..], bool) read_file_all(const char[..] path) {
	auto (r, ok) = reader_open(path, OpenRead, 0);
	char[..] data = str_empty();
	if (!ok) {
		return (str_empty(), false);
	}
	defer r.close();
	for (;;) {
		char chunk[8192] = {0};
		auto (n, rok) = r.read(ranged(chunk, sizeof(chunk)));
		if (!rok) {
			str_free(&data);
			return (str_empty(), false);
		}
		if (n == 0) {
			break;
		}
		if (!str_append(&data, ranged(chunk, n))) {
			str_free(&data);
			return (str_empty(), false);
		}
	}
	return (data, true);
}

bool (TaskStore *store).load(const char[..] path) {
	JsonError err = {0};
	store.init();
	auto (text, tok) = read_file_all(path);
	if (!tok) {
		return false;
	}
	defer str_free(&text);
	JsonValue *root = json_parse_n(ptr(text), len(text), &err);
	if (root == NULL) {
		return false;
	}
	defer json_free(root);
	if (root.type != JSON_OBJECT) {
		return false;
	}
	const JsonValue *tasks = json_object_get(root, "tasks");
	if (tasks == NULL || tasks.type != JSON_ARRAY) {
		return true;
	}
	for (size_t i = 0; i < json_array_size(tasks); i++) {
		const JsonValue *item = json_array_get(tasks, i);
		Task t = {0};
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
			break;
		}
		t.clear(); /* add deep-copied; drop temps */
	}
	store.dirty = false;
	store.sort();
	return true;
}

bool (TaskStore *store).save(const char[..] path) {
	char tmp[1024] = {0};
	if (!store_ensure_parent_dir(path)) {
		return false;
	}
	JsonValue *root = json_new_object();
	if (root == NULL) {
		return false;
	}
	defer json_free(root);
	if (!json_object_set(root, "version", json_new_number(1))) {
		return false;
	}
	JsonValue *arr = json_new_array();
	if (arr == NULL) {
		return false;
	}
	if (!json_object_set(root, "tasks", arr)) {
		return false;
	}
	arr = json_object_get_mutable(root, "tasks");
	for (int i = 0; i < store.count; i++) {
		Task *t = &store.tasks[i];
		JsonValue *obj = json_new_object();
		if (obj == NULL) {
			return false;
		}
		if (!json_object_set(obj, "id", json_new_string_n(ptr(t.id), len(t.id))) ||
			!json_object_set(obj, "status", json_new_string_n(ptr(t.status), len(t.status))) ||
			!json_object_set(obj, "title", json_new_string_n(ptr(t.title), len(t.title))) ||
			!json_object_set(obj, "cc", json_new_string_n(ptr(t.cc), len(t.cc))) ||
			!json_object_set(obj, "tags", json_new_string_n(ptr(t.tags), len(t.tags))) ||
			!json_object_set(obj, "updated", json_new_string_n(ptr(t.updated), len(t.updated)))) {
			json_free(obj);
			return false;
		}
		if (!json_array_append(arr, obj)) {
			return false;
		}
	}
	char *text = json_stringify(root);
	if (text == NULL) {
		return false;
	}
	defer free(text);
	pool p {
		char[..] tmp_path = {0};
		if (!p.append(&tmp_path, path) || !p.append(&tmp_path, ".tmp")) {
			return false;
		}
		(void)cstr_write(ranged(tmp, sizeof(tmp)), tmp_path);
		{
			auto (w, wok) = writer_open(ranged(tmp, strlen(tmp)), OpenWrite | OpenCreate | OpenTrunc, 0);
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
		store_rotate_backups(path);
		if (!fs_rename(ranged(tmp, strlen(tmp)), path)) {
			/* If we moved the live file to bak.1, try to put it back. */
			char bak1[BackupPathCap] = {0};
			if (backup_slot_path(ranged(bak1, sizeof(bak1)), path, 1)) {
				auto (b, bok) = fs_stat(ranged(bak1, strlen(bak1)));
				auto (cur, cok) = fs_stat(path);
				(void)cur;
				if (bok && b.kind == KindFile && !cok) {
					(void)fs_rename(ranged(bak1, strlen(bak1)), path);
				}
			}
			(void)fs_remove(ranged(tmp, strlen(tmp)));
			return false;
		}
	}
	store.dirty = false;
	return true;
}

bool store_load(TaskStore *store, const char[..] path) {
	if (store == NULL) {
		return false;
	}
	return store.load(path);
}

bool store_save(TaskStore *store, const char[..] path) {
	if (store == NULL) {
		return false;
	}
	return store.save(path);
}

bool store_import_file(TaskStore *store, const char[..] src, const char[..] dst) {
	static TaskStore seed;
	if (store == NULL) {
		return false;
	}
	seed.init();
	if (!seed.load(src)) {
		return false;
	}
	if (!store.load(dst)) {
		store.init();
	}
	(void)store.merge(&seed);
	store.dirty = true;
	return store.save(dst);
}

static int store_find_id(const TaskStore *store, const char[..] id) {
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

bool (TaskStore *local).merge(const TaskStore *incoming) {
	bool changed = false;
	if (incoming == NULL) {
		return false;
	}
	for (int i = 0; i < incoming.count; i++) {
		const Task *src = &incoming.tasks[i];
		int at = store_find_id(local, src.id);
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

bool store_merge(TaskStore *local, const TaskStore *incoming) {
	if (local == NULL) {
		return false;
	}
	return local.merge(incoming);
}
