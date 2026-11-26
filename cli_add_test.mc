/* Integration: ./modfocus add argv path (build binary if missing). */
import "store";
import "model";
import "fs";
import "os";
import "path";
import "str";

#include <assert.h>
#include <stdio.h>
#include <string.h>

static Cmd g_cmd;

static int run_cmd(const char[..] path, const char[..]* args, size_t nargs) {
	Cmd z = { 0 };
	g_cmd = z;
	g_cmd.init(path, args, nargs);
	if (!g_cmd.stdio(StdIn, IoNull) || !g_cmd.stdio(StdOut, IoNull) || !g_cmd.stdio(StdErr, IoNull)) {
		g_cmd.close();
		return -1;
	}
	if (!g_cmd.start()) {
		g_cmd.close();
		return -1;
	}
	auto (code, ok) = g_cmd.wait();
	g_cmd.close();
	if (!ok) {
		return -1;
	}
	return code;
}

static int ensure_modfocus() {
	auto (info, ok) = fs_stat("./modfocus");
	if (ok && info.kind == KindFile) {
		return 0;
	}
	{
		const char[..] args[5] = { 0 };
		args[0] = "build";
		args[1] = "-M";
		args[2] = ".";
		args[3] = "-o";
		args[4] = "modfocus";
		assert_eq(run_cmd("modc", args, 5), 0);
	}
	{
		auto (built, bok) = fs_stat("./modfocus");
		assert(bok && built.kind == KindFile);
	}
	return 0;
}

static int test_cli_add_flags() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-cli-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		{
			const char[..] args[10] = { 0 };
			args[0] = "--db";
			args[1] = db;
			args[2] = "add";
			args[3] = "--attn";
			args[4] = "Brian Jessica";
			args[5] = "--tag";
			args[6] = "errand";
			args[7] = "hello #work #home";
			assert_eq(run_cmd("./modfocus", args, 8), 0);
		}
		{
			TaskStore loaded = { 0 };
			loaded.init();
			assert(loaded.load(db));
			assert_eq(loaded.count, 1);
			assert(loaded.tasks[0].title.eq("hello"));
			assert(loaded.tasks[0].tags.eq("#work #home #errand"));
			assert(loaded.tasks[0].cc.eq("Brian, Jessica"));
			assert(loaded.tasks[0].status.eq("A:Inbox"));
			assert(len(loaded.tasks[0].id) > 0);
		}
		(void)fs_remove(db);
	}
	return 0;
}

static int test_cli_add_at_tokens() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-cli-at-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		{
			const char[..] args[5] = { 0 };
			args[0] = "--db";
			args[1] = db;
			args[2] = "add";
			args[3] = "@Charles review PR #work";
			assert_eq(run_cmd("./modfocus", args, 4), 0);
		}
		{
			TaskStore loaded = { 0 };
			loaded.init();
			assert(loaded.load(db));
			assert_eq(loaded.count, 1);
			assert(loaded.tasks[0].title.eq("review PR"));
			assert(loaded.tasks[0].tags.eq("#work"));
			assert(loaded.tasks[0].cc.eq("Charles"));
		}
		(void)fs_remove(db);
	}
	return 0;
}

static int test_cli_add_empty_fails() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-cli-empty-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "tasks.json");
		assert(pok);
		{
			const char[..] args[3] = { 0 };
			args[0] = "--db";
			args[1] = db;
			args[2] = "add";
			assert_eq(run_cmd("./modfocus", args, 3), 1);
		}
		{
			auto (info, ok) = fs_stat(db);
			assert(!ok || info.kind != KindFile);
		}
	}
	return 0;
}

static int test_cli_add_creates_db() {
	pool p {
		auto (dir, dok) = fs_mkdir_temp(&p, "", "modfocus-cli-new-");
		assert(dok && len(dir) > 0);
		defer(void)fs_remove(dir);
		auto (db, pok) = path_join(&p, dir, "fresh.json");
		assert(pok);
		{
			auto (info, ok) = fs_stat(db);
			assert(!ok || info.kind != KindFile);
		}
		{
			const char[..] args[5] = { 0 };
			args[0] = "--db";
			args[1] = db;
			args[2] = "add";
			args[3] = "first";
			assert_eq(run_cmd("./modfocus", args, 4), 0);
		}
		{
			TaskStore loaded = { 0 };
			loaded.init();
			assert(loaded.load(db));
			assert_eq(loaded.count, 1);
			assert(loaded.tasks[0].title.eq("first"));
		}
		(void)fs_remove(db);
	}
	return 0;
}

int main() {
	assert_eq(ensure_modfocus(), 0);
	assert_eq(test_cli_add_flags(), 0);
	assert_eq(test_cli_add_at_tokens(), 0);
	assert_eq(test_cli_add_empty_fails(), 0);
	assert_eq(test_cli_add_creates_db(), 0);
	return 0;
}
