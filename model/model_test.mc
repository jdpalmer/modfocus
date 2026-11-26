/* model — attn/tags normalize, title parse, complete, status cycle. */
import "model";
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

static int test_attn_space_split() {
	TaskStore store = { 0 };
	store.init();
	int at = add_titled(&store, "x");
	assert(at >= 0);
	assert(store.set_cc(at, "Brian Jessica"));
	assert(store.tasks[at].cc.eq("Brian, Jessica"));
	assert(store.set_cc(at, "  Ada   Lovelace  "));
	assert(store.tasks[at].cc.eq("Ada Lovelace"));
	assert(store.set_cc(at, "@Charles"));
	assert(store.tasks[at].cc.eq("Charles"));
	assert(store.set_cc(at, "@Brian @Jessica"));
	assert(store.tasks[at].cc.eq("Brian, Jessica"));
	return 0;
}

static int test_attn_comma_split() {
	TaskStore store = { 0 };
	store.init();
	int at = add_titled(&store, "x");
	assert(at >= 0);
	assert(store.set_cc(at, "Brian,  Jessica"));
	assert(store.tasks[at].cc.eq("Brian, Jessica"));
	assert(store.set_cc(at, "Ann Marie, Bob"));
	assert(store.tasks[at].cc.eq("Ann Marie, Bob"));
	return 0;
}

static int test_tags_normalize() {
	TaskStore store = { 0 };
	store.init();
	int at = add_titled(&store, "x");
	assert(at >= 0);
	assert(store.set_tags(at, "work, #home HOME"));
	assert(store.tasks[at].tags.eq("#work #home"));
	return 0;
}

static int test_parse_title_tags() {
	pool p {
		auto (title, tags, ok) = model_parse_title_tags(&p, "buy milk #home #errands");
		assert(ok);
		assert(title.eq("buy milk"));
		assert(tags.eq("#home #errands"));
	}
	pool p2 {
		auto (title, tags, ok) = model_parse_title_tags(&p2, "fix #12 stuck");
		assert(ok);
		assert(title.eq("fix #12 stuck"));
		assert(len(tags) == 0);
	}
	pool p3 {
		auto (title, tags, ok) = model_parse_title_tags(&p3, "#solo");
		assert(ok);
		assert(len(title) == 0);
		assert(tags.eq("#solo"));
	}
	return 0;
}

static int test_parse_task_line_at() {
	pool p {
		auto (title, tags, attn, ok) = model_parse_task_line(&p, "@Charles review PR #work");
		assert(ok);
		assert(title.eq("review PR"));
		assert(tags.eq("#work"));
		assert(attn.eq("Charles"));
	}
	pool p2 {
		auto (title, tags, attn, ok) = model_parse_task_line(&p2, "@Brian @Jessica buy milk #home");
		assert(ok);
		assert(title.eq("buy milk"));
		assert(tags.eq("#home"));
		assert(attn.eq("Brian Jessica"));
	}
	pool p3 {
		auto (title, tags, attn, ok) = model_parse_task_line(&p3, "plain @Ada");
		(void)tags;
		assert(ok);
		assert(title.eq("plain"));
		assert(attn.eq("Ada"));
	}
	pool p4 {
		auto (title, tags, attn, ok) = model_parse_task_line(&p4, "user@host keep");
		(void)tags;
		assert(ok);
		/* Glued @ is not a token (email-ish). */
		assert(title.eq("user@host keep"));
		assert(len(attn) == 0);
	}
	return 0;
}

/* Edit/add contract: parse line then set_title/set_tags (empty tags clears). */
static int test_title_line_apply() {
	TaskStore store = { 0 };
	store.init();
	int at = add_titled(&store, "seed");
	assert(at >= 0);
	assert(store.set_tags(at, "#old"));
	pool p {
		auto (title, tags, ok) = model_parse_title_tags(&p, "buy milk #home");
		assert(ok && len(title) > 0);
		assert(store.set_title(at, title));
		assert(store.set_tags(at, tags));
		assert(store.tasks[at].title.eq("buy milk"));
		assert(store.tasks[at].tags.eq("#home"));
	}
	pool p2 {
		auto (title, tags, ok) = model_parse_title_tags(&p2, "plain title");
		assert(ok && len(title) > 0);
		assert(len(tags) == 0);
		assert(store.set_title(at, title));
		assert(store.set_tags(at, tags));
		assert(store.tasks[at].title.eq("plain title"));
		assert(len(store.tasks[at].tags) == 0);
	}
	pool p3 {
		auto (title, tags, ok) = model_parse_title_tags(&p3, "   ");
		(void)tags;
		assert(ok);
		assert(len(title) == 0);
	}
	pool p4 {
		auto (title, tags, ok) = model_parse_title_tags(&p4, "#only");
		assert(ok);
		assert(len(title) == 0);
		assert(tags.eq("#only"));
	}
	return 0;
}

static int test_format_title_tags() {
	char buf[128] = { 0 };
	assert(model_format_title_tags("hello", "#a #b", ranged(buf, sizeof(buf))));
	assert(ranged(buf, strlen(buf)).eq("hello #a #b"));
	assert(model_format_title_tags("only", "", ranged(buf, sizeof(buf))));
	assert(ranged(buf, strlen(buf)).eq("only"));
	assert(model_format_task_line("review", "#work", "Brian, Jessica", ranged(buf, sizeof(buf))));
	assert(ranged(buf, strlen(buf)).eq("@Brian, @Jessica review #work"));
	return 0;
}

static int test_attn_complete() {
	TaskStore store = { 0 };
	char out[64] = { 0 };
	store.init();
	int a = add_titled(&store, "one");
	int b = add_titled(&store, "two");
	assert(a >= 0 && b >= 0);
	assert(store.set_cc(a, "Brian, Jessica"));
	assert(store.set_cc(b, "Charles"));
	assert(store.attn_complete("Br", ranged(out, sizeof(out))));
	assert(ranged(out, strlen(out)).eq("Brian"));
	assert(store.attn_complete("C", ranged(out, sizeof(out))));
	assert(ranged(out, strlen(out)).eq("Charles"));
	assert(!store.attn_complete("Zz", ranged(out, sizeof(out))));
	return 0;
}

static int test_tag_complete() {
	TaskStore store = { 0 };
	char out[64] = { 0 };
	store.init();
	int at = add_titled(&store, "x");
	assert(at >= 0);
	assert(store.set_tags(at, "#home #work"));
	assert(store.tag_complete("#ho", ranged(out, sizeof(out))));
	assert(ranged(out, strlen(out)).eq("#home"));
	assert(store.tag_complete("wo", ranged(out, sizeof(out))));
	assert(ranged(out, strlen(out)).eq("#work"));
	return 0;
}

/* Multi-match: extend to the shared LCP; no progress → false. */
static int test_complete_ambiguous_lcp() {
	TaskStore store = { 0 };
	char out[64] = { 0 };
	store.init();
	int a = add_titled(&store, "one");
	int b = add_titled(&store, "two");
	assert(a >= 0 && b >= 0);
	assert(store.set_cc(a, "Brian"));
	assert(store.set_cc(b, "Bridget"));
	assert(store.attn_complete("B", ranged(out, sizeof(out))));
	assert(ranged(out, strlen(out)).eq("Bri"));
	assert(!store.attn_complete("Bri", ranged(out, sizeof(out))));
	assert(store.set_tags(a, "#work #workshop"));
	assert(store.tag_complete("#w", ranged(out, sizeof(out))));
	assert(ranged(out, strlen(out)).eq("#work"));
	assert(!store.tag_complete("#work", ranged(out, sizeof(out))));
	return 0;
}

static int test_cycle_status_skips_complete() {
	TaskStore store = { 0 };
	store.init();
	int at = add_titled(&store, "x");
	assert(at >= 0);
	assert(store.tasks[at].status.eq("A:Inbox"));
	assert(store.cycle_status(at));
	assert(store.tasks[at].status.eq("B:Now"));
	/* Walk until Waiting, then next should be Someday (skip Complete). */
	assert(store.set_status(at, "E:Waiting"));
	assert(store.cycle_status(at));
	assert(store.tasks[at].status.eq("G:Someday"));
	assert(store.cycle_status_prev(at));
	assert(store.tasks[at].status.eq("E:Waiting"));
	return 0;
}

static int test_parse_status_focus() {
	pool p {
		auto (a, aok) = model_parse_status_focus(&p, ":now");
		assert(aok && a.eq("B:Now"));
		auto (b, bok) = model_parse_status_focus(&p, "waiting");
		assert(bok && b.eq("E:Waiting"));
		auto (c, cok) = model_parse_status_focus(&p, "A:Inbox");
		assert(cok && c.eq("A:Inbox"));
		auto (_d, dok) = model_parse_status_focus(&p, ":nope");
		(void)_d;
		assert(!dok);
	}
	return 0;
}

static int test_build_visible_status() {
	TaskStore store = { 0 };
	ViewFilter f = { 0 };
	int visible[8] = { 0 };
	store.init();
	f.init();
	int a = add_titled(&store, "inbox");
	int b = add_titled(&store, "now");
	assert(a >= 0 && b >= 0);
	assert(store.set_status(b, "B:Now"));
	(void)str_set(&f.status, "B:Now");
	int n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], b);
	return 0;
}

static int test_build_visible_text() {
	TaskStore store = { 0 };
	ViewFilter f = { 0 };
	int visible[8] = { 0 };
	store.init();
	f.init();
	int a = add_titled(&store, "buy milk");
	int b = add_titled(&store, "write docs");
	int c = add_titled(&store, "other");
	assert(a >= 0 && b >= 0 && c >= 0);
	assert(store.set_cc(b, "Ada"));
	assert(store.set_tags(c, "#errands"));
	(void)str_set(&f.text, "milk");
	int n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], a);
	(void)str_set(&f.text, "ada");
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], b);
	(void)str_set(&f.text, "@Ada");
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], b);
	(void)str_set(&f.text, "errand");
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], c);
	(void)str_set(&f.text, "inbox");
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 3);
	(void)str_set(&f.text, "nomatch");
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 0);
	return 0;
}

static int test_build_visible_focus() {
	TaskStore store = { 0 };
	ViewFilter f = { 0 };
	int visible[8] = { 0 };
	store.init();
	f.init();
	int a = add_titled(&store, "alpha");
	int b = add_titled(&store, "beta");
	assert(a >= 0 && b >= 0);
	assert(store.set_cc(a, "Brian"));
	assert(store.set_tags(b, "#home"));
	assert(store.set_status(a, "F:Complete"));
	(void)str_set(&f.cc, "Brian");
	int n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 0);
	/* Complete hidden unless show_complete. */
	f.show_complete = true;
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], a);
	f.show_complete = false;
	(void)str_set(&f.cc, "");
	(void)str_set(&f.tag, "#home");
	n = store.build_visible(&f, ranged(visible, 8));
	assert_eq(n, 1);
	assert_eq(visible[0], b);
	return 0;
}

static int test_sort_and_rev() {
	TaskStore store = { 0 };
	store.init();
	int a = add_titled(&store, "zeta");
	int b = add_titled(&store, "alpha");
	assert(a >= 0 && b >= 0);
	assert(store.set_status(a, "C:Soon"));
	assert(store.set_status(b, "A:Inbox"));
	store.sort();
	assert(store.tasks[0].title.eq("alpha"));
	assert(store.tasks[1].title.eq("zeta"));
	store.sort_rev();
	assert(store.tasks[0].title.eq("zeta"));
	assert(store.tasks[1].title.eq("alpha"));
	return 0;
}

int main() {
	assert_eq(test_attn_space_split(), 0);
	assert_eq(test_attn_comma_split(), 0);
	assert_eq(test_tags_normalize(), 0);
	assert_eq(test_parse_title_tags(), 0);
	assert_eq(test_parse_task_line_at(), 0);
	assert_eq(test_title_line_apply(), 0);
	assert_eq(test_format_title_tags(), 0);
	assert_eq(test_attn_complete(), 0);
	assert_eq(test_tag_complete(), 0);
	assert_eq(test_complete_ambiguous_lcp(), 0);
	assert_eq(test_cycle_status_skips_complete(), 0);
	assert_eq(test_parse_status_focus(), 0);
	assert_eq(test_build_visible_text(), 0);
	assert_eq(test_build_visible_status(), 0);
	assert_eq(test_build_visible_focus(), 0);
	assert_eq(test_sort_and_rev(), 0);
	return 0;
}
