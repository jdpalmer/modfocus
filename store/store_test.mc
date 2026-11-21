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
	assert_eq(test_merge_lww(), 0);
	assert_eq(test_ensure_parent_dir(), 0);
	assert_eq(test_default_path_mfdb(), 0);
	return 0;
}
