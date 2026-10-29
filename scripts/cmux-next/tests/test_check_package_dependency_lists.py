#!/usr/bin/env python3
"""check-package-dependency-lists.py: the CmuxNextAppTests dependencies stay one sorted entry per
line, so two pull requests that each add a module merge without a conflict (2026-10-20: six
pull requests were CONFLICTING again within twenty minutes of a rebase on that list)."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "check-package-dependency-lists.py"
SPEC = importlib.util.spec_from_file_location("check_package_dependency_lists", SCRIPT)
assert SPEC and SPEC.loader
lint = importlib.util.module_from_spec(SPEC)
sys.modules["check_package_dependency_lists"] = lint
SPEC.loader.exec_module(lint)


def manifest(*entries: str) -> str:
    body = "".join(f"                {entry}\n" for entry in entries)
    return (
        "let package = Package(\n"
        "    targets: [\n"
        "        .testTarget(\n"
        '            name: "CmuxNextAppTests",\n'
        f"            dependencies: [ {lint.MARKER}\n"
        f"{body}"
        "            ],\n"
        "            swiftSettings: uiSwiftSettings\n"
        "        ),\n"
        "    ]\n"
        ")\n"
    )


BASE = ('"CmuxNextActions",', '"CmuxNextFeed",', '"CmuxNextTabs",',
        '.product(name: "CmuxHomeCore", package: "CmuxHomeCore"),')


class CheckTests(unittest.TestCase):
    def problems(self, text: str) -> list[str]:
        return lint.check(text, fix=False)[0]

    def test_the_committed_manifest_is_canonical(self):
        self.assertEqual(self.problems(lint.DEFAULT_MANIFEST.read_text(encoding="utf-8")), [])

    def test_a_sorted_list_passes(self):
        self.assertEqual(self.problems(manifest(*BASE)), [])

    def test_an_unsorted_list_fails_and_fix_sorts_it_with_its_comments(self):
        text = manifest('"CmuxNextTabs",', "// Feed's tests read the timeline.", '"CmuxNextFeed",')
        self.assertIn("CmuxNextAppTests: entries are not sorted (run with --fix)", self.problems(text))
        fixed = lint.check(text, fix=True)[1]
        self.assertEqual(fixed, manifest("// Feed's tests read the timeline.", '"CmuxNextFeed",', '"CmuxNextTabs",'))
        self.assertEqual(self.problems(fixed), [])

    def test_two_entries_on_a_line_fail(self):
        problems = self.problems(manifest('"CmuxNextActions", "CmuxNextFeed",'))
        self.assertTrue(any("one entry per line" in p for p in problems), problems)

    def test_a_missing_trailing_comma_fails(self):
        problems = self.problems(manifest('"CmuxNextActions",', '"CmuxNextFeed"'))
        self.assertTrue(any("must end in a comma" in p for p in problems), problems)

    def test_a_duplicate_fails(self):
        problems = self.problems(manifest('"CmuxNextFeed",', '"CmuxNextFeed",'))
        self.assertIn('CmuxNextAppTests: duplicate entry "CmuxNextFeed",', problems)

    def test_a_trailing_comment_fails(self):
        problems = self.problems(manifest('"CmuxNextFeed", // the timeline'))
        self.assertTrue(any("own line above" in p for p in problems), problems)

    def test_the_app_tests_list_must_carry_the_marker(self):
        text = manifest(*BASE).replace(f" {lint.MARKER}", "")
        self.assertTrue(any("lacks the marker" in p for p in self.problems(text)))

    def test_fix_on_the_command_line_rewrites_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Package.swift"
            path.write_text(manifest('"CmuxNextTabs",', '"CmuxNextFeed",'), encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "--fix", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.read_text(encoding="utf-8"), manifest('"CmuxNextFeed",', '"CmuxNextTabs",'))


class ImportTests(unittest.TestCase):
    """A target that imports another local target declares it (2026-10-24: CmuxNextDaemonTests imported
    CmuxNextCompat undeclared, and incremental builds linked a stale object against an old Mutex symbol)."""

    PACKAGE = (
        "let package = Package(\n"
        "    targets: [\n"
        "        .target(\n"
        '            name: "CmuxNextCompat",\n'
        "            dependencies: []\n"
        "        ),\n"
        "        .target(\n"
        '            name: "CmuxNextDaemon",\n'
        '            dependencies: ["CmuxNextCompat"]\n'
        "        ),\n"
        "        .testTarget(\n"
        '            name: "CmuxNextDaemonTests",\n'
        "            dependencies: [DEPS]\n"
        "        ),\n"
        "    ]\n"
        ")\n"
    )

    def problems(self, deps: str, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in ("Sources/CmuxNextCompat", "Sources/CmuxNextDaemon", "Tests/CmuxNextDaemonTests"):
                (root / folder).mkdir(parents=True)
            (root / "Sources/CmuxNextDaemon/A.swift").write_text("import CmuxNextCompat\n", encoding="utf-8")
            (root / "Tests/CmuxNextDaemonTests/RetryWakeFolderTests.swift").write_text(source, encoding="utf-8")
            text = self.PACKAGE.replace("DEPS", deps)
            with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()):
                return lint.import_problems(text, root)

    def test_an_undeclared_local_import_fails(self):
        problems = self.problems('"CmuxNextDaemon"', "import CmuxNextCompat\n@testable import CmuxNextDaemon\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("CmuxNextDaemonTests: imports CmuxNextCompat but does not declare it", problems[0])

    def test_a_declared_import_and_a_system_import_pass(self):
        self.assertEqual(self.problems('"CmuxNextCompat", "CmuxNextDaemon"',
                                       "import Foundation\nimport CmuxNextCompat\n@testable import CmuxNextDaemon\n"), [])

    def test_a_baseline_line_that_is_fixed_must_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Sources/CmuxNextCompat").mkdir(parents=True)
            text = "let package = Package(\n    targets: [\n        .target(\n            name: \"CmuxNextCompat\"\n        ),\n    ]\n)\n"
            with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset({"CmuxNextApp: CmuxNextFileGrid"})):
                problems = lint.import_problems(text, root)
        self.assertEqual(problems, ["IMPORT_BASELINE lists CmuxNextApp: CmuxNextFileGrid, which is declared or gone now: drop its line"])

    def test_the_committed_package_declares_its_imports(self):
        root = lint.DEFAULT_MANIFEST.parent
        self.assertEqual(lint.import_problems(lint.DEFAULT_MANIFEST.read_text(encoding="utf-8"), root), [])


class MergeTests(unittest.TestCase):
    """Git's own line merge (what GitHub runs) on two branches that each add a module."""

    def git(self, *args: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@e", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["git", "-C", self.root, *args], env=env, capture_output=True, text=True)

    def branch(self, name: str, *entries: str) -> None:
        self.git("checkout", "-q", "-b", name, "main")
        Path(self.root, "Package.swift").write_text(manifest(*sorted(entries)), encoding="utf-8")
        self.git("commit", "-qam", name)

    def merge(self, left: tuple, right: tuple) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            self.root = tmp
            self.git("init", "-q", "-b", "main")
            Path(tmp, "Package.swift").write_text(manifest(*BASE), encoding="utf-8")
            self.git("add", ".")
            self.git("commit", "-qm", "base")
            self.branch("left", *BASE, *left)
            self.branch("right", *BASE, *right)
            result = self.git("merge", "-q", "--no-edit", "left")
            result.merged = Path(tmp, "Package.swift").read_text(encoding="utf-8")
            return result

    def test_additions_in_different_places_merge_cleanly_and_stay_sorted(self):
        result = self.merge(('"CmuxNextBrowserHistory",',), ('"CmuxNextNowPlaying",',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(lint.check(result.merged, fix=False)[0], [])
        self.assertIn('"CmuxNextBrowserHistory",', result.merged)
        self.assertIn('"CmuxNextNowPlaying",', result.merged)


# Three targets in the shapes Package.swift has: an inline list, a multi-line list with several entries per line
# and a marked sorted list.
FIX_MANIFEST = (
    "let package = Package(\n"
    "    targets: [\n"
    "        .target(\n"
    '            name: "CmuxNextCompat"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextHome",\n'
    '            dependencies: ["CmuxNextCompat"],\n'
    "        ),\n"
    "        .testTarget(\n"
    '            name: "CmuxNextHomeEngineTests",\n'
    "            dependencies: [\n"
    '                "CmuxNextHomeEngine", "CmuxNextDaemon",\n'
    '                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),\n'
    "            ],\n"
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextHomeEngine"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextDaemon"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextAppCore"\n'
    "        ),\n"
    "        .testTarget(\n"
    '            name: "CmuxNextAppTests",\n'
    "            dependencies: [  MARKER_PLACEHOLDER\n"
    '                "CmuxNextApp",\n'
    '                "CmuxNextApps",\n'
    '                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),\n'
    "            ],\n"
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextApp"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextApps"\n'
    "        ),\n"
    "    ]\n"
    ")\n"
)


class FixImportsTests(unittest.TestCase):
    """--fix-imports declares a new undeclared import where the list keeps its shape (2026-10-29: the two pushes
    #27173 and #27219 repaired by hand)."""

    def manifest_text(self) -> str:
        return FIX_MANIFEST.replace("MARKER_PLACEHOLDER", lint.MARKER)

    def test_a_marked_list_gets_the_entry_in_sorted_order(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextAppTests", "CmuxNextAppCore")
        self.assertIn('                "CmuxNextApp",\n                "CmuxNextAppCore",\n                "CmuxNextApps",\n',
                      fixed)
        self.assertEqual(lint.check(fixed, fix=False)[0], [])

    def test_a_multi_line_list_gets_the_entry_on_its_own_line_before_the_bracket(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextHomeEngineTests", "CmuxNextHome")
        self.assertIn('.product(name: "CmuxHomeCore", package: "CmuxHomeCore"),\n                "CmuxNextHome",\n'
                      "            ],", fixed)

    def test_an_inline_list_gets_the_entry_before_the_bracket(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextHome", "CmuxNextDaemon")
        self.assertIn('dependencies: ["CmuxNextCompat", "CmuxNextDaemon"],', fixed)

    def test_a_target_without_dependencies_gets_a_list(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextCompat", "CmuxNextDaemon")
        self.assertIn('name: "CmuxNextCompat"\n            dependencies: ["CmuxNextDaemon"],\n', fixed)

    def test_only_the_named_target_changes(self):
        # CmuxNextApp is a prefix of CmuxNextApps and CmuxNextAppTests: the exact name is the one changed.
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextApp", "CmuxNextDaemon")
        self.assertIn('name: "CmuxNextApp"\n            dependencies: ["CmuxNextDaemon"],\n', fixed)
        self.assertEqual(fixed.count("CmuxNextDaemon"), self.manifest_text().count("CmuxNextDaemon") + 1)

    def test_an_unknown_target_is_an_error(self):
        with self.assertRaises(lint.FixError):
            lint.add_dependency(self.manifest_text(), "CmuxNextNope", "CmuxNextDaemon")

    def run_script(self, root: Path, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCRIPT), *args, str(root / "Package.swift")],
                              capture_output=True, text=True)

    def test_the_two_real_incidents_are_found_named_and_fixed(self):
        # a63986a4: a CmuxNextHomeEngineTests file gained `import CmuxNextHome`; e875485c: a CmuxNextAppTests file
        # gained `@testable import CmuxNextAppCore`. Neither target declared it.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text(self.manifest_text(), encoding="utf-8")
            for folder, text in (("Tests/CmuxNextHomeEngineTests/Unanswered.swift", "import CmuxNextHome\n"),
                                 ("Tests/CmuxNextAppTests/Restore.swift", "@testable import CmuxNextAppCore\n"),
                                 ("Sources/CmuxNextCompat/A.swift", "import Foundation\n")):
                (root / folder).parent.mkdir(parents=True, exist_ok=True)
                (root / folder).write_text(text, encoding="utf-8")
            with unittest.mock.patch.dict(os.environ, {}):
                red = self.run_script(root, "--json")
            self.assertEqual(red.returncode, 1, red.stderr)
            self.assertIn('Fix: add "CmuxNextHome" to the dependencies of CmuxNextHomeEngineTests', red.stderr)
            self.assertIn('Fix: add "CmuxNextAppCore" to the dependencies of CmuxNextAppTests', red.stderr)
            missing = json.loads(red.stdout)["missing"]
            self.assertEqual(missing, [{"target": "CmuxNextAppTests", "module": "CmuxNextAppCore"},
                                       {"target": "CmuxNextHomeEngineTests", "module": "CmuxNextHome"}])

            fixed = self.run_script(root, "--fix-imports", "--json")

            # The fixture holds none of IMPORT_BASELINE's targets, so its lines read as stale here; nothing else is red.
            after = json.loads(fixed.stdout.splitlines()[-1])
            self.assertEqual(after["missing"], [])
            self.assertEqual([p for p in after["problems"] if "IMPORT_BASELINE lists" not in p], [])
            self.assertIn("declared CmuxNextHome in the dependencies of CmuxNextHomeEngineTests", fixed.stdout)
            again = self.run_script(root, "--json")
            self.assertNotIn("does not declare", again.stderr)


HEAL_SPEC = importlib.util.spec_from_file_location("package_deps_heal", HERE.parent / "package_deps_heal.py")
heal = importlib.util.module_from_spec(HEAL_SPEC)
sys.modules["package_deps_heal"] = heal
HEAL_SPEC.loader.exec_module(heal)


class HealTests(unittest.TestCase):
    """package_deps_heal.py: a direct push that adds an undeclared import becomes a fix pull request on its own
    branch, never a push to feat-cmux-next."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="package-deps-heal-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.origin = self.root / "origin.git"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@e", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "feat-cmux-next", str(self.origin)], check=True,
                       env=self.env)
        self.git("init", "-q", "-b", "feat-cmux-next", cwd=self.root, target=str(self.repo))
        self.git("remote", "add", "origin", str(self.origin))
        package = self.repo / heal.MANIFEST
        package.parent.mkdir(parents=True)
        package.write_text(FIX_MANIFEST.replace("MARKER_PLACEHOLDER", lint.MARKER), encoding="utf-8")
        self.write("Tests/CmuxNextHomeEngineTests/Old.swift", "import CmuxNextHomeEngine\n")
        self.write("Sources/CmuxNextCompat/A.swift", "import Foundation\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.git("push", "-q", "origin", "feat-cmux-next")

    def git(self, *args, cwd=None, target=None):
        command = ["git", *([] if target else ["-C", str(self.repo)]), *args, *([target] if target else [])]
        return subprocess.run(command, cwd=cwd, env=self.env, text=True, capture_output=True, check=True).stdout

    def write(self, relative, text):
        path = self.repo / heal.MANIFEST
        path = path.parent / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def bad_push(self):
        """The a63986a4 shape: a test file gains `import CmuxNextHome`, pushed straight to the branch."""
        self.write("Tests/CmuxNextHomeEngineTests/Unanswered.swift", "import CmuxNextHome\nimport CmuxNextHomeEngine\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "test(home): an unanswered group start says the cloud did not answer")
        self.git("push", "-q", "origin", "feat-cmux-next")
        return self.git("rev-parse", "HEAD").strip()

    def test_a_green_tree_plans_nothing(self):
        out = self.root / "plan"
        with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()), \
                unittest.mock.patch.object(heal, "load_check", lambda: lint):
            result = heal.plan(self.repo, "HEAD", out)
        self.assertEqual(result, {"red": "false"})
        self.assertFalse(out.exists())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def plan(self):
        out = self.root / "plan"
        with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()), \
                unittest.mock.patch.object(heal, "load_check", lambda: lint):
            return heal.plan(self.repo, "HEAD", out, "manaflow-ai/cmux", "https://ci/run/1"), out

    def test_a_simulated_bad_push_plans_the_fix_pull_request(self):
        offending = self.bad_push()

        result, out = self.plan()

        self.assertEqual(result["red"], "true")
        self.assertEqual(result["fixable"], "true")
        self.assertTrue(result["branch"].startswith("autofix/package-deps-"), result)
        self.assertEqual((out / "branch").read_text().strip(), result["branch"])
        self.assertEqual((out / "title").read_text().strip(),
                         "fix(cmux-next): CmuxNextHomeEngineTests declares CmuxNextHome, which it imports")
        body = (out / "body.md").read_text()
        self.assertIn(f"https://github.com/manaflow-ai/cmux/commit/{offending}", body, "names the offending commit")
        self.assertIn("test(home): an unanswered group start", body)
        self.assertIn("| `CmuxNextHomeEngineTests` | `CmuxNextHome` |", body)
        self.assertIn("Opened by https://ci/run/1.", body)
        self.assertIn(offending[:10], (out / "commit-message").read_text())
        self.assertEqual((out / "labels").read_text().strip(), "risk:low")
        manifest = (self.repo / heal.MANIFEST).read_text()
        self.assertIn('"CmuxNextHome",', manifest)
        changed = self.git("diff", "--name-only").split()
        self.assertEqual(changed, [heal.MANIFEST], "only Package.swift changes")
        self.assertEqual(lint.missing_imports(manifest, (self.repo / heal.MANIFEST).parent), [])

    def test_the_same_gap_plans_the_same_branch(self):
        self.bad_push()
        first, _ = self.plan()
        self.git("checkout", "-q", "--", heal.MANIFEST)
        self.write("Sources/CmuxNextCompat/B.swift", "import Foundation\n")  # an unrelated later push
        second, _ = self.plan()
        self.assertEqual(first["branch"], second["branch"])

    def fake_gh(self, listed="[]"):
        tools = self.root / "bin"
        tools.mkdir(exist_ok=True)
        log = self.root / "gh.log"
        (tools / "gh").write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >> "{log}"\n'
            f'case "$1 $2" in "pr list") echo \'{listed}\' ;; "pr create") echo https://github.com/x/y/pull/9 ;; esac\n')
        (tools / "gh").chmod(0o755)
        return tools, log

    def test_open_pushes_only_the_autofix_branch_and_opens_its_pull_request(self):
        self.bad_push()
        result, out = self.plan()
        before = subprocess.run(["git", "-C", str(self.origin), "rev-parse", "feat-cmux-next"], env=self.env,
                                text=True, capture_output=True).stdout.strip()
        tools, log = self.fake_gh()

        with unittest.mock.patch.dict(os.environ, {**self.env, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}):
            url = heal.open_pr(self.repo, out)

        self.assertEqual(url, "https://github.com/x/y/pull/9")
        heads = subprocess.run(["git", "-C", str(self.origin), "for-each-ref", "--format=%(refname:short) %(objectname)",
                                "refs/heads"], env=self.env, text=True, capture_output=True).stdout.split("\n")
        self.assertIn(f"feat-cmux-next {before}", heads, "feat-cmux-next must not move")
        self.assertTrue(any(h.startswith(result["branch"] + " ") for h in heads), heads)
        create = [line for line in log.read_text().splitlines() if line.startswith("pr create")]
        self.assertEqual(len(create), 1, log.read_text())
        self.assertIn("--base feat-cmux-next", create[0])
        self.assertIn(f"--head {result['branch']}", create[0])
        self.assertIn("--label risk:low", create[0])

    def test_open_does_nothing_when_the_branch_already_has_an_open_pull_request(self):
        self.bad_push()
        _, out = self.plan()
        tools, log = self.fake_gh(listed='[{"url": "https://github.com/x/y/pull/8"}]')
        with unittest.mock.patch.dict(os.environ, {**self.env, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}):
            self.assertEqual(heal.open_pr(self.repo, out), "already open: https://github.com/x/y/pull/8")
        self.assertNotIn("pr create", log.read_text())

    def test_open_refuses_any_branch_but_an_autofix_one(self):
        self.bad_push()
        _, out = self.plan()
        (out / "branch").write_text("feat-cmux-next\n")
        with self.assertRaises(SystemExit):
            heal.open_pr(self.repo, out)


if __name__ == "__main__":
    unittest.main()
