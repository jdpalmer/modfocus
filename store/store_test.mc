/* store — save/load roundtrip, LWW merge, parent dir, default path. */
import "store";
import "model";
import "fs";
import "os";
import "path";
import "str";

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <utime.h>
#include "host_time.h"

static(char[..], bool) bak_slot([[region]] Pool * p, const char[..] db, int n) {
	char suf[16] = { 0 };
	char[..] out = { 0 };
	snprintf(suf, sizeof(suf), ".bak.%d", n);
	if (!p.append(&out, db) || !p.append(&out, ranged(suf, strlen(suf)))) {
		return (str_empty(), false);
	}
	return (out, true);
}

/* Make path look older than BackupMinAgeSec so the next save rotates. */
static bool age_file(const char[..] path, int64_t age_sec) {
	char z[BackupPathCap] = { 0 };
	int64_t now = time(0);
	int64_t t = now - age_sec;
	if (len(path) + 1 > sizeof(z)) {
		return false;
	}
	memcpy(z, ptr(path), len(path));
	if (t <= 0) {
		t = 1;
	}
	{
		struct utimbuf times = {
			.actime = t,
			.modtime = t
		};
		return utime(z, &times) == 0;
	}
}

static bool load_title(const char[..] path, char[..] dst) {
	TaskStore loaded = { 0 };
	loaded.init();
	if (!loaded.load(path) || loaded.count < 1) {
		return false;
	}
	return cstr_write(dst, loaded.tasks[0].title) > 0 || len(loaded.tasks[0].title) == 0;
}

static int add_titled(TaskStore* store, const char[..] title) {
	Task t = { 0 };
	if (!str_set(&t.title, title)) {
		t.clear();
		return -1;
	}
	if (!store.add(&t)) {
		t.clear();
		return -1;
	}
	t.clear();
	return store.count - 1;
}

static int test_save_load_roundtrip() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-store-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		TaskStore store = { 0 };
		TaskStore loaded = { 0 };
		store.init();
		int at = add_titled(&store, "milk");
		assert(at >= 0);
		assert(store.set_cc(at, "Brian Jessica"));
		assert(store.set_tags(at, "#home errand"));
		assert(store.save(db));
		loaded.init();
		assert(loaded.load(db));
		assert_eq(loaded.count, 1);
		assert(str_eq(loaded.tasks[0].title, "milk"));
		assert(str_eq(loaded.tasks[0].cc, "Brian, Jessica"));
		assert(str_eq(loaded.tasks[0].tags, "#home #errand"));
		assert(str_eq(loaded.tasks[0].status, "A:Inbox"));
		assert(len(loaded.tasks[0].id) > 0);
		(void)fs_remove(db);
	}
	return 0;
}

static int test_merge_lww() {
	TaskStore local = { 0 };
	TaskStore incoming = { 0 };
	local.init();
	incoming.init();
	int a = add_titled(&local, "old title");
	assert(a >= 0);
	/* Seed a stable id + older stamp on local. */
	assert(str_set(&local.tasks[a].id, "t99"));
	assert(str_set(&local.tasks[a].updated, "2020-01-01T00:00:00Z"));
	assert(str_set(&local.tasks[a].title, "old title"));
	/* Incoming same id, newer stamp wins whole task. */
	int b = add_titled(&incoming, "new title");
	assert(b >= 0);
	assert(str_set(&incoming.tasks[b].id, "t99"));
	assert(str_set(&incoming.tasks[b].updated, "2021-06-01T12:00:00Z"));
	assert(str_set(&incoming.tasks[b].title, "new title"));
	assert(str_set(&incoming.tasks[b].cc, "Ada"));
	assert(local.merge(&incoming));
	assert_eq(local.count, 1);
	assert(str_eq(local.tasks[0].title, "new title"));
	assert(str_eq(local.tasks[0].cc, "Ada"));
	/* Equal updated keeps local. */
	assert(str_set(&incoming.tasks[b].title, "ignored"));
	assert(str_set(&incoming.tasks[b].updated, "2021-06-01T12:00:00Z"));
	assert(!local.merge(&incoming));
	assert(str_eq(local.tasks[0].title, "new title"));
	/* Incoming-only id is added. */
	int c = add_titled(&incoming, "extra");
	assert(c >= 0);
	assert(str_set(&incoming.tasks[c].id, "t100"));
	assert(local.merge(&incoming));
	assert_eq(local.count, 2);
	return 0;
}

static int test_merge_local_newer() {
	TaskStore local = { 0 };
	TaskStore incoming = { 0 };
	local.init();
	incoming.init();
	int a = add_titled(&local, "local wins");
	assert(a >= 0);
	assert(str_set(&local.tasks[a].id, "t7"));
	assert(str_set(&local.tasks[a].updated, "2024-01-01T00:00:00Z"));
	assert(str_set(&local.tasks[a].cc, "Local"));
	int b = add_titled(&incoming, "stale remote");
	assert(b >= 0);
	assert(str_set(&incoming.tasks[b].id, "t7"));
	assert(str_set(&incoming.tasks[b].updated, "2020-01-01T00:00:00Z"));
	assert(str_set(&incoming.tasks[b].title, "stale remote"));
	assert(str_set(&incoming.tasks[b].cc, "Remote"));
	assert(!local.merge(&incoming));
	assert_eq(local.count, 1);
	assert(str_eq(local.tasks[0].title, "local wins"));
	assert(str_eq(local.tasks[0].cc, "Local"));
	return 0;
}

static int test_ensure_parent_dir() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-parent-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (child, cok) = path_join(&p, dir, "nest");
		assert(cok);
		auto (db, pok) = path_join(&p, child, "tasks.json");
		assert(pok);
		assert(store_ensure_parent_dir(db));
		auto (info, iok) = fs_stat(child);
		assert(iok && info.kind == KindDir);
		/* Already a directory is fine. */
		assert(store_ensure_parent_dir(db));
		(void)fs_remove(child);
	}
	return 0;
}

static int test_next_id_after_load() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-nextid-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		TaskStore store = { 0 };
		store.init();
		int a = add_titled(&store, "first");
		int b = add_titled(&store, "second");
		assert(a >= 0 && b >= 0);
		assert(str_set(&store.tasks[a].id, "t5"));
		assert(str_set(&store.tasks[b].id, "t12"));
		assert(store.save(db));
		TaskStore loaded = { 0 };
		loaded.init();
		assert(loaded.load(db));
		assert_eq(loaded.count, 2);
		int c = add_titled(&loaded, "third");
		assert(c >= 0);
		assert(str_eq(loaded.tasks[c].id, "t13"));
		assert(!str_eq(loaded.tasks[c].id, "t5"));
		assert(!str_eq(loaded.tasks[c].id, "t12"));
		(void)fs_remove(db);
	}
	return 0;
}

static int test_import_file() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-import-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (src, sok) = path_join(&p, dir, "seed.json");
		auto (dst, dok2) = path_join(&p, dir, "dest.json");
		assert(sok && dok2);
		TaskStore seed = { 0 };
		TaskStore store = { 0 };
		seed.init();
		int at = add_titled(&seed, "from seed");
		assert(at >= 0);
		assert(str_set(&seed.tasks[at].id, "t42"));
		assert(str_set(&seed.tasks[at].updated, "2022-01-01T00:00:00Z"));
		assert(seed.set_cc(at, "Ada"));
		assert(seed.save(src));
		/* Missing destination is created. */
		{
			auto (info, ok) = fs_stat(dst);
			assert(!ok || info.kind != KindFile);
		}
		store.init();
		assert(store_import_file(&store, src, dst));
		assert_eq(store.count, 1);
		assert(str_eq(store.tasks[0].title, "from seed"));
		assert(str_eq(store.tasks[0].id, "t42"));
		{
			auto (info, ok) = fs_stat(dst);
			assert(ok && info.kind == KindFile);
		}
		/* Re-import with a newer stamp updates the live task and saves. */
		assert(str_set(&seed.tasks[at].title, "updated seed"));
		assert(str_set(&seed.tasks[at].updated, "2023-01-01T00:00:00Z"));
		assert(seed.save(src));
		assert(store_import_file(&store, src, dst));
		assert_eq(store.count, 1);
		assert(str_eq(store.tasks[0].title, "updated seed"));
		{
			TaskStore loaded = { 0 };
			loaded.init();
			assert(loaded.load(dst));
			assert_eq(loaded.count, 1);
			assert(str_eq(loaded.tasks[0].title, "updated seed"));
		}
		(void)fs_remove(src);
		(void)fs_remove(dst);
	}
	return 0;
}

static int test_backup_rotate() {
	pool p {
		char title[64] = { 0 };
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-bak-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		auto (bak1, b1ok) = bak_slot(&p, db, 1);
		auto (bak2, b2ok) = bak_slot(&p, db, 2);
		assert(b1ok && b2ok);
		TaskStore store = { 0 };
		store.init();
		int at = add_titled(&store, "one");
		assert(at >= 0);
		assert(store.save(db));
		/* First save: live only, no backup yet. */
		{
			auto (info, ok) = fs_stat(bak1);
			assert(!ok || info.kind != KindFile);
		}
		assert(store.set_title(at, "two"));
		assert(store.save(db));
		/* Second save copies prior live → bak.1 (live stays until atomic replace). */
		assert(load_title(bak1, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "one"));
		assert(load_title(db, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "two"));
		assert(store.set_title(at, "three"));
		assert(store.save(db));
		/* Within the hour: no new generation; bak.1 stays "one". */
		{
			auto (info, ok) = fs_stat(bak2);
			assert(!ok || info.kind != KindFile);
		}
		assert(load_title(bak1, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "one"));
		assert(load_title(db, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "three"));
		/* Age bak.1 so the next save rotates again. */
		assert(age_file(bak1, BackupMinAgeSec + 60));
		assert(store.set_title(at, "four"));
		assert(store.save(db));
		assert(load_title(bak2, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "one"));
		assert(load_title(bak1, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "three"));
		assert(load_title(db, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "four"));
		(void)fs_remove(bak2);
		(void)fs_remove(bak1);
		(void)fs_remove(db);
	}
	return 0;
}

static int test_recover_primary() {
	pool p {
		char title[64] = { 0 };
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-recover-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		auto (bak1, b1ok) = bak_slot(&p, db, 1);
		assert(b1ok);
		TaskStore store = { 0 };
		store.init();
		int at = add_titled(&store, "safe");
		assert(at >= 0);
		assert(store.save(db));
		assert(store.set_title(at, "newer"));
		assert(store.save(db));
		assert(fs_remove(db));
		{
			auto (info, ok) = fs_stat(db);
			assert(!ok || info.kind != KindFile);
		}
		assert(store_recover_primary(db));
		assert(load_title(db, ranged(title, sizeof(title))));
		assert(str_eq(ranged(title, strlen(title)), "safe"));
		(void)fs_remove(bak1);
		(void)fs_remove(db);
	}
	return 0;
}

static int test_default_path_mfdb() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-mfdb-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "custom.json");
		assert(pok);
		assert(os_set_env("MFDB", db));
		defer(void)os_set_env("MFDB", "");
		auto (path, ok) = store_default_path(&p);
		assert(ok);
		assert(str_eq(path, db));
	}
	return 0;
}

int main() {
	assert_eq(test_save_load_roundtrip(), 0);
	assert_eq(test_next_id_after_load(), 0);
	assert_eq(test_merge_lww(), 0);
	assert_eq(test_merge_local_newer(), 0);
	assert_eq(test_ensure_parent_dir(), 0);
	assert_eq(test_import_file(), 0);
	assert_eq(test_backup_rotate(), 0);
	assert_eq(test_recover_primary(), 0);
	assert_eq(test_default_path_mfdb(), 0);
	return 0;
}
