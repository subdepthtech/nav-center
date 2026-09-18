import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from atsim import cli as atsim


class AtsimTests(unittest.TestCase):
    def test_application_scan_uses_artifact_text_and_posting(self):
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = Path(tmp) / "applications" / "2099-01-01_Test_Cyber_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text(
                "\n".join(
                    [
                        "# Cybersecurity Engineer",
                        "",
                        "Requires RMF, NIST 800-53, CISSP, Kubernetes, Terraform, and incident response.",
                    ]
                ),
                encoding="utf-8",
            )
            (app_dir / "Resume_2099-01-01_Test_Cyber_Role.md").write_text(
                "# Source resume missing generated contact details",
                encoding="utf-8",
            )
            (artifacts_dir / "Resume_2099-01-01_Test_Cyber_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "",
                        "Summary",
                        "Security leader with RMF and NIST 800-53 experience.",
                        "",
                        "Skills",
                        "RMF, NIST 800-53, CISSP, incident response",
                        "",
                        "Professional Experience",
                        "- Led incident response exercises and compliance work.",
                        "",
                        "Education",
                        "Master of Science in Cybersecurity",
                        "",
                        "Certifications",
                        "CISSP",
                    ]
                ),
                encoding="utf-8",
            )

            report = atsim.build_report(app_dir)

            self.assertEqual(report["input"]["job_description"], str((app_dir / "posting.md").resolve()))
            self.assertEqual(
                report["input"]["text_source"],
                str((artifacts_dir / "Resume_2099-01-01_Test_Cyber_Role.docx.txt").resolve()),
            )
            self.assertIn("rmf", report["keywords"]["matched"])
            self.assertIn("terraform", report["keywords"]["missing"])
            self.assertEqual(report["contact"]["email"], "austin@example.com")
            self.assertGreater(report["scores"]["overall"], 40)

    def test_doctor_json_reports_offline_auth_model(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = atsim.main(["--json", "doctor"])

        payload = json.loads(stdout.getvalue())

        self.assertEqual(result, 0)
        self.assertEqual(payload["tool"], "atsim")
        self.assertFalse(payload["auth"]["required"])
        self.assertEqual(payload["auth"]["source"], "not_required")
        self.assertTrue(payload["checks"]["master_resume"])

    def test_applications_list_and_resolve_use_stable_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "applications"
            first = root / "2099-01-01_Acme_Security_Engineer"
            second = root / "2099-01-02_Beta_Risk_Analyst"
            (first / "artifacts").mkdir(parents=True)
            (second / "artifacts").mkdir(parents=True)
            (first / "posting.md").write_text("Requires RMF.", encoding="utf-8")
            (first / "artifacts" / "Resume_2099-01-01_Acme_Security_Engineer.docx.txt").write_text(
                "Summary\nSecurity leader.",
                encoding="utf-8",
            )

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = atsim.main(["--json", "applications", "list", "--root", str(root), "--limit", "1"])

            listed = json.loads(stdout.getvalue())

            self.assertEqual(result, 0)
            self.assertEqual(listed["total"], 2)
            self.assertEqual(len(listed["applications"]), 1)
            self.assertEqual(listed["applications"][0]["id"], "2099-01-02_Beta_Risk_Analyst")

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = atsim.main(["--json", "applications", "resolve", "acme", "--root", str(root)])

            resolved = json.loads(stdout.getvalue())

            self.assertEqual(result, 0)
            self.assertEqual(resolved["id"], "2099-01-01_Acme_Security_Engineer")
            self.assertTrue(resolved["has_posting"])
            self.assertEqual(
                resolved["resume_sources"],
                ["Resume_2099-01-01_Acme_Security_Engineer.docx.txt"],
            )

    def test_json_errors_are_machine_readable(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = atsim.main(["--json", "applications", "resolve", "missing-role"])

        payload = json.loads(stdout.getvalue())

        self.assertEqual(result, 1)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["type"], "runtime_error")
        self.assertEqual(stderr.getvalue(), "")

    def test_artifact_read_outputs_json_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "ats-report.json"
            artifact.write_text(json.dumps({"scores": {"overall": 88}}), encoding="utf-8")

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = atsim.main(["--json", "artifact", "read", str(artifact)])

            self.assertEqual(result, 0)
            self.assertEqual(json.loads(stdout.getvalue()), {"scores": {"overall": 88}})

    def test_formatting_warnings_detect_common_parse_risks(self):
        text = "\n".join(
            [
                "Austin Tucker",
                "austin@example.com",
                "Summary",
                "| Skill | Years |",
                "| RMF | 10 |",
                "US Army        Cyber Center        Mar 2025",
                "US Army        Cyber Center        Mar 2025",
                "US Army        Cyber Center        Mar 2025",
                "US Army        Cyber Center        Mar 2025",
                "US Army        Cyber Center        Mar 2025",
                "Date: 2025/03",
            ]
        )

        warnings = atsim.formatting_warnings(Path("resume.md"), text, ["summary"], None)

        self.assertTrue(any("Table-like markdown" in warning for warning in warnings))
        self.assertTrue(any("multi-column" in warning for warning in warnings))
        self.assertTrue(any("date formats" in warning for warning in warnings))
        self.assertTrue(any("No phone" in warning for warning in warnings))

    def test_keywords_command_skill_extraction_supports_cyber_terms(self):
        skills = atsim.extract_relevant_skills(
            "This role requires DISA STIG, POA&M, Splunk, TS/SCI, FedRAMP, and GRC experience.",
            atsim.load_skills(None),
        )

        self.assertIn("disa stig", skills)
        self.assertIn("poa&m", skills)
        self.assertIn("splunk", skills)
        self.assertIn("ts/sci", skills)
        self.assertIn("fedramp", skills)
        self.assertIn("grc", skills)
        self.assertIn("terraform", atsim.extract_relevant_skills("Terraform.", atsim.load_skills(None)))

    def test_ambiguous_short_skills_do_not_match_normal_prose(self):
        skill_bank = atsim.load_skills(None)

        prose_skills = atsim.extract_relevant_skills(
            "We go deep on roadmaps and help teams go faster.",
            skill_bank,
        )
        go_skills = atsim.extract_relevant_skills(
            "Experience building Go and Golang services is required.",
            skill_bank,
        )

        self.assertNotIn("go", prose_skills)
        self.assertIn("go", go_skills)

    def test_suggestions_classify_supported_and_blocked_keyword_gaps(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Cloud_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text(
                "Requires RMF, Terraform, Kubernetes, and incident response.",
                encoding="utf-8",
            )
            (artifacts_dir / "Resume_2099-01-01_Test_Cloud_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "",
                        "Summary",
                        "Security leader with RMF and incident response experience.",
                        "",
                        "Skills",
                        "RMF, incident response",
                        "",
                        "Professional Experience",
                        "- Led incident response exercises and compliance work.",
                        "",
                        "Education",
                        "Master of Science in Cybersecurity",
                    ]
                ),
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text(
                "\n".join(
                    [
                        "skills:",
                        "  cloud:",
                        "    - Terraform",
                        "  cyber:",
                        "    - Incident Response & Recovery",
                    ]
                ),
                encoding="utf-8",
            )

            bundle = atsim.build_suggestion_bundle(app_dir, master_path=master_path)
            keyword_suggestions = {
                item["id"]: item
                for item in bundle["suggestions"]
                if item["category"] == "keyword"
            }
            supported = [item for item in keyword_suggestions.values() if item["master_supported"] is True]
            blocked = [item for item in keyword_suggestions.values() if item["blocked_reason"]]

            self.assertTrue(any("terraform" in item["evidence"].lower() for item in supported))
            self.assertTrue(any("kubernetes" in item["evidence"].lower() for item in blocked))

    def test_suggest_command_writes_default_application_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Report_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Report_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "Summary",
                        "Security leader with RMF experience.",
                        "Professional Experience",
                        "- Led RMF compliance work.",
                    ]
                ),
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = atsim.main(["suggest", str(app_dir), "--master", str(master_path)])

            self.assertEqual(result, 0)
            self.assertTrue((artifacts_dir / "ats-suggestions.json").exists())
            self.assertTrue((artifacts_dir / "ats-suggestions.md").exists())
            self.assertTrue((artifacts_dir / "ats-fix-prompt.md").exists())
            self.assertIn("ATS Fix Suggestions", (artifacts_dir / "ats-suggestions.md").read_text(encoding="utf-8"))
            prompt_text = (artifacts_dir / "ats-fix-prompt.md").read_text(encoding="utf-8")
            self.assertIn("JSON diffs", prompt_text)
            self.assertIn("Security leader with RMF experience.", prompt_text)
            self.assertIn("Requires RMF and Terraform.", prompt_text)

    def test_verify_diffs_accepts_grounded_supported_diff(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Verify_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Verify_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "",
                        "Summary",
                        "Security leader with RMF experience.",
                        "",
                        "Professional Experience",
                        "- Led RMF compliance work.",
                    ]
                ),
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")
            suggestions = atsim.build_suggestion_bundle(app_dir, master_path=master_path)
            suggestions_path = artifacts_dir / "ats-suggestions.json"
            suggestions_path.write_text(json.dumps(suggestions), encoding="utf-8")
            diffs_path = artifacts_dir / "ats-llm-diffs.raw.json"
            diffs_path.write_text(
                json.dumps(
                    {
                        "diffs": [
                            {
                                "suggestion_id": "kw-001",
                                "path_hint": "summary",
                                "original": "Security leader with RMF experience.",
                                "replacement": "Security leader with RMF and Terraform infrastructure experience.",
                                "reason": "Adds a supported keyword from the job description.",
                                "master_evidence": ["Terraform"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            result = atsim.verify_diffs_bundle(app_dir, diffs_path, suggestions_path)

            self.assertEqual(result["summary"]["accepted"], 1)
            self.assertEqual(result["summary"]["rejected"], 0)

    def test_verify_diffs_rejects_blocked_keyword_and_invented_metric(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Reject_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF, Kubernetes, and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Reject_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "",
                        "Summary",
                        "Security leader with RMF experience.",
                        "",
                        "Professional Experience",
                        "- Led RMF compliance work.",
                    ]
                ),
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")
            suggestions = atsim.build_suggestion_bundle(app_dir, master_path=master_path)
            blocked_kubernetes = next(
                item
                for item in suggestions["suggestions"]
                if "kubernetes" in item["evidence"].lower()
            )
            suggestions_path = artifacts_dir / "ats-suggestions.json"
            suggestions_path.write_text(json.dumps(suggestions), encoding="utf-8")
            diffs_path = artifacts_dir / "ats-llm-diffs.raw.json"
            diffs_path.write_text(
                json.dumps(
                    {
                        "diffs": [
                            {
                                "suggestion_id": blocked_kubernetes["id"],
                                "path_hint": "summary",
                                "original": "Security leader with RMF experience.",
                                "replacement": "Security leader with RMF, Kubernetes, and 40% faster delivery.",
                                "reason": "Adds job keywords.",
                                "master_evidence": ["Terraform"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            result = atsim.verify_diffs_bundle(app_dir, diffs_path, suggestions_path)
            reasons = result["results"][0]["reasons"]

            self.assertEqual(result["summary"]["accepted"], 0)
            self.assertEqual(result["summary"]["rejected"], 1)
            self.assertTrue(any("blocked keyword" in reason for reason in reasons))
            self.assertTrue(any("unsupported metric" in reason for reason in reasons))

    def test_verify_diffs_command_writes_default_application_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Command_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Command_Role.docx.txt").write_text(
                "Austin Tucker, CISSP\nSummary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")
            suggestions = atsim.build_suggestion_bundle(app_dir, master_path=master_path)
            suggestions_path = artifacts_dir / "ats-suggestions.json"
            suggestions_path.write_text(json.dumps(suggestions), encoding="utf-8")
            diffs_path = artifacts_dir / "ats-llm-diffs.raw.json"
            diffs_path.write_text(
                json.dumps(
                    {
                        "diffs": [
                            {
                                "suggestion_id": "kw-001",
                                "path_hint": "summary",
                                "original": "Security leader with RMF experience.",
                                "replacement": "Security leader with RMF and Terraform infrastructure experience.",
                                "reason": "Adds a supported keyword.",
                                "master_evidence": ["Terraform"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = atsim.main(["verify-diffs", str(app_dir), "--diffs", str(diffs_path)])

            self.assertEqual(result, 0)
            self.assertTrue((artifacts_dir / "ats-verified-diffs.json").exists())
            self.assertTrue((artifacts_dir / "ats-verified-diffs.md").exists())
            self.assertIn("ATS Verified Diffs", (artifacts_dir / "ats-verified-diffs.md").read_text(encoding="utf-8"))

    def test_verify_diffs_rejects_contact_edit_even_with_valid_suggestion(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Contact_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Contact_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "Summary",
                        "Security leader with RMF experience.",
                    ]
                ),
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")
            suggestions = atsim.build_suggestion_bundle(app_dir, master_path=master_path)
            suggestions_path = artifacts_dir / "ats-suggestions.json"
            suggestions_path.write_text(json.dumps(suggestions), encoding="utf-8")
            diffs_path = artifacts_dir / "ats-llm-diffs.raw.json"
            diffs_path.write_text(
                json.dumps(
                    {
                        "diffs": [
                            {
                                "suggestion_id": "kw-001",
                                "path_hint": "summary",
                                "original": "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                                "replacement": "jane@example.com | 555-999-0000 | linkedin.com/in/janedoe",
                                "reason": "Unsafe contact edit.",
                                "master_evidence": ["Terraform"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            result = atsim.verify_diffs_bundle(app_dir, diffs_path, suggestions_path)
            reasons = result["results"][0]["reasons"]

            self.assertEqual(result["summary"]["accepted"], 0)
            self.assertTrue(any("contact" in reason for reason in reasons))
            self.assertTrue(any("blocked section" in reason for reason in reasons))

    def test_verify_diffs_rejects_unrelated_plain_number_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Number_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Number_Role.docx.txt").write_text(
                "Summary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")
            suggestions = atsim.build_suggestion_bundle(app_dir, master_path=master_path)
            suggestions_path = artifacts_dir / "ats-suggestions.json"
            suggestions_path.write_text(json.dumps(suggestions), encoding="utf-8")
            diffs_path = artifacts_dir / "ats-llm-diffs.raw.json"
            diffs_path.write_text(
                json.dumps(
                    {
                        "diffs": [
                            {
                                "suggestion_id": "kw-001",
                                "path_hint": "summary",
                                "original": "Security leader with RMF experience.",
                                "replacement": "Security leader with RMF experience leading 12 audit workstreams.",
                                "reason": "Unsafe unrelated claim.",
                                "master_evidence": ["Terraform"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            result = atsim.verify_diffs_bundle(app_dir, diffs_path, suggestions_path)
            reasons = result["results"][0]["reasons"]

            self.assertEqual(result["summary"]["accepted"], 0)
            self.assertTrue(any("unsupported metric" in reason for reason in reasons))
            self.assertTrue(any("does not include referenced supported keyword" in reason for reason in reasons))

    def test_parse_json_payload_from_text_accepts_markdown_fence(self):
        payload = atsim.parse_json_payload_from_text(
            "Here are the diffs:\n```json\n{\"diffs\": []}\n```"
        )

        self.assertEqual(payload, {"diffs": []})
        self.assertEqual(
            atsim.parse_json_payload_from_text("Result: [{\"suggestion_id\": \"kw-001\"}]"),
            [{"suggestion_id": "kw-001"}],
        )

    def test_external_prompt_bundle_redacts_headingless_identity_and_paths(self):
        bundle = {
            "input": {
                "resume": "/tmp/app/Resume_Test.md",
                "text_source": "/tmp/app/artifacts/Resume_Test.docx.txt",
                "job_description": "/tmp/app/posting.md",
                "skills_file": None,
            },
            "prompt_context": {
                "resume_text_source": "/tmp/app/artifacts/Resume_Test.docx.txt",
                "resume_text": "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "Security leader with RMF experience.",
                    ]
                ),
                "job_description_text": "Requires RMF.",
            },
        }

        safe_bundle = atsim.external_prompt_bundle(bundle)
        prompt_text = json.dumps(safe_bundle)

        self.assertNotIn("Austin Tucker", prompt_text)
        self.assertNotIn("austin@example.com", prompt_text)
        self.assertNotIn("555-123-4567", prompt_text)
        self.assertNotIn("linkedin.com/in/austinktucker", prompt_text)
        self.assertNotIn("/tmp/app", prompt_text)
        self.assertIn("Resume_Test.docx.txt", prompt_text)

    def test_draft_diffs_command_uses_opencode_backend_and_writes_raw_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Draft_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Draft_Role.docx.txt").write_text(
                "\n".join(
                    [
                        "Austin Tucker, CISSP",
                        "austin@example.com | 555-123-4567 | linkedin.com/in/austinktucker",
                        "",
                        "Summary",
                        "Security leader with RMF experience.",
                    ]
                ),
                encoding="utf-8",
            )
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")

            captured = {}
            original_runner = atsim.run_opencode_sdk_draft

            def fake_runner(prompt, *, model, agent, sdk_runner, timeout):
                captured["prompt"] = prompt
                captured["model"] = model
                captured["agent"] = agent
                captured["sdk_runner"] = sdk_runner
                captured["timeout"] = timeout
                return json.dumps(
                    {
                        "diffs": [
                            {
                                "suggestion_id": "kw-001",
                                "path_hint": "summary",
                                "original": "Security leader with RMF experience.",
                                "replacement": "Security leader with RMF and Terraform infrastructure experience.",
                                "reason": "Adds a supported keyword.",
                                "master_evidence": ["Terraform"],
                            }
                        ]
                    }
                )

            atsim.run_opencode_sdk_draft = fake_runner
            try:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    result = atsim.main(
                        [
                            "draft-diffs",
                            str(app_dir),
                            "--master",
                            str(master_path),
                            "--model",
                            "zai/test-model",
                            "--agent",
                            "build",
                            "--timeout",
                            "12",
                        ]
                    )
            finally:
                atsim.run_opencode_sdk_draft = original_runner

            output_path = artifacts_dir / "ats-llm-diffs.raw.json"
            payload = json.loads(output_path.read_text(encoding="utf-8"))

            self.assertEqual(result, 0)
            self.assertEqual(captured["model"], "zai/test-model")
            self.assertEqual(captured["agent"], "build")
            self.assertEqual(captured["sdk_runner"], atsim.DEFAULT_OPENCODE_SDK_RUNNER)
            self.assertEqual(captured["timeout"], 12)
            self.assertIn("Return only a valid JSON object", captured["prompt"])
            self.assertIn("Security leader with RMF experience.", captured["prompt"])
            self.assertNotIn("austin@example.com", captured["prompt"])
            self.assertNotIn("555-123-4567", captured["prompt"])
            self.assertNotIn("linkedin.com/in/austinktucker", captured["prompt"])
            self.assertNotIn(str(tmp_path), captured["prompt"])
            self.assertEqual(payload["diffs"][0]["suggestion_id"], "kw-001")
            self.assertIn("verify-diffs", stdout.getvalue())

    def test_draft_diffs_rebuilds_suggestions_when_sources_are_overridden(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Override_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Override_Role.docx.txt").write_text(
                "Summary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )
            stale_suggestions = {
                "input": {"job_description": "stale.md"},
                "allowed_edit_paths": atsim.ALLOWED_EDIT_PATHS,
                "blocked_edit_fields": atsim.BLOCKED_EDIT_FIELDS,
                "prompt_context": {
                    "resume_text_source": "stale.txt",
                    "resume_text": "Summary\nStale resume.",
                    "job_description_text": "Requires Kubernetes.",
                },
                "suggestions": [],
            }
            (artifacts_dir / "ats-suggestions.json").write_text(
                json.dumps(stale_suggestions),
                encoding="utf-8",
            )
            jd_path = tmp_path / "override-posting.md"
            jd_path.write_text("Requires RMF and Terraform.", encoding="utf-8")
            master_path = tmp_path / "master.yaml"
            master_path.write_text("- Terraform", encoding="utf-8")

            captured = {}
            original_runner = atsim.run_opencode_sdk_draft

            def fake_runner(prompt, *, model, agent, sdk_runner, timeout):
                captured["prompt"] = prompt
                return json.dumps({"diffs": []})

            atsim.run_opencode_sdk_draft = fake_runner
            try:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    result = atsim.main(
                        [
                            "draft-diffs",
                            str(app_dir),
                            "--jd",
                            str(jd_path),
                            "--master",
                            str(master_path),
                        ]
                    )
            finally:
                atsim.run_opencode_sdk_draft = original_runner

            self.assertEqual(result, 0)
            self.assertIn("Requires RMF and Terraform.", captured["prompt"])
            self.assertIn("Terraform", captured["prompt"])
            self.assertNotIn("Requires Kubernetes.", captured["prompt"])
            self.assertNotIn("Stale resume.", captured["prompt"])

    def test_draft_diffs_skips_backend_when_no_suggestions_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_No_Suggestions_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_No_Suggestions_Role.docx.txt").write_text(
                "Summary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )
            suggestions = {
                "input": {"text_source": str(artifacts_dir / "Resume_2099-01-01_Test_No_Suggestions_Role.docx.txt")},
                "suggestion_summary": {"total": 0},
                "allowed_edit_paths": atsim.ALLOWED_EDIT_PATHS,
                "blocked_edit_fields": atsim.BLOCKED_EDIT_FIELDS,
                "prompt_context": {
                    "resume_text_source": "Resume_2099-01-01_Test_No_Suggestions_Role.docx.txt",
                    "resume_text": "Summary\nSecurity leader with RMF experience.",
                    "job_description_text": "Requires RMF.",
                },
                "suggestions": [],
            }
            (artifacts_dir / "ats-suggestions.json").write_text(
                json.dumps(suggestions),
                encoding="utf-8",
            )

            original_runner = atsim.run_opencode_sdk_draft

            def fail_runner(*args, **kwargs):
                raise AssertionError("backend should not be called when there are no suggestions")

            atsim.run_opencode_sdk_draft = fail_runner
            try:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    result = atsim.main(["draft-diffs", str(app_dir)])
            finally:
                atsim.run_opencode_sdk_draft = original_runner

            output_path = artifacts_dir / "ats-llm-diffs.raw.json"
            payload = json.loads(output_path.read_text(encoding="utf-8"))

            self.assertEqual(result, 0)
            self.assertEqual(payload, {"diffs": []})
            self.assertIn("Diffs: 0", stdout.getvalue())

    def test_draft_diffs_skips_backend_when_suggestions_are_blocked_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Blocked_Only_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires FedRAMP.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Blocked_Only_Role.docx.txt").write_text(
                "Summary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )
            suggestions = {
                "suggestions": [
                    {
                        "id": "kw-001",
                        "category": "keyword",
                        "blocked_reason": "Keyword was not found in master resume evidence.",
                        "evidence": "Missing likely JD skill `fedramp`.",
                    }
                ],
            }
            (artifacts_dir / "ats-suggestions.json").write_text(
                json.dumps(suggestions),
                encoding="utf-8",
            )

            original_runner = atsim.run_opencode_sdk_draft

            def fail_runner(*args, **kwargs):
                raise AssertionError("backend should not be called for blocked-only suggestions")

            atsim.run_opencode_sdk_draft = fail_runner
            try:
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    result = atsim.main(["draft-diffs", str(app_dir)])
            finally:
                atsim.run_opencode_sdk_draft = original_runner

            payload = json.loads((artifacts_dir / "ats-llm-diffs.raw.json").read_text(encoding="utf-8"))

            self.assertEqual(result, 0)
            self.assertEqual(payload, {"diffs": []})

    def test_draft_diffs_writes_failure_artifact_when_backend_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Backend_Fails_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)

            (app_dir / "posting.md").write_text("Requires RMF and Terraform.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Backend_Fails_Role.docx.txt").write_text(
                "Summary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )
            suggestions = {
                "input": {"text_source": str(artifacts_dir / "Resume_2099-01-01_Test_Backend_Fails_Role.docx.txt")},
                "suggestions": [
                    {
                        "id": "kw-001",
                        "category": "keyword",
                        "master_supported": True,
                        "master_evidence": ["Terraform"],
                        "evidence": "Missing likely JD skill `terraform`.",
                    }
                ],
                "prompt_context": {
                    "resume_text": "Summary\nSecurity leader with RMF experience.",
                    "job_description_text": "Requires RMF and Terraform.",
                },
                "allowed_edit_paths": atsim.ALLOWED_EDIT_PATHS,
                "blocked_edit_fields": atsim.BLOCKED_EDIT_FIELDS,
            }
            (artifacts_dir / "ats-suggestions.json").write_text(
                json.dumps(suggestions),
                encoding="utf-8",
            )

            original_runner = atsim.run_opencode_sdk_draft

            def fail_runner(*args, **kwargs):
                raise RuntimeError("session.prompt failed: {}")

            atsim.run_opencode_sdk_draft = fail_runner
            try:
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    result = atsim.main(["draft-diffs", str(app_dir)])
            finally:
                atsim.run_opencode_sdk_draft = original_runner

            payload = json.loads((artifacts_dir / "ats-llm-diffs.raw.json").read_text(encoding="utf-8"))

            self.assertEqual(result, 1)
            self.assertEqual(payload["diffs"], [])
            self.assertIn("session.prompt failed", payload["draft_error"]["message"])
            self.assertIn("session.prompt failed", stderr.getvalue())

    def test_verify_diffs_missing_file_fails_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app_dir = tmp_path / "applications" / "2099-01-01_Test_Missing_Diffs_Role"
            artifacts_dir = app_dir / "artifacts"
            artifacts_dir.mkdir(parents=True)
            (app_dir / "posting.md").write_text("Requires RMF.", encoding="utf-8")
            (artifacts_dir / "Resume_2099-01-01_Test_Missing_Diffs_Role.docx.txt").write_text(
                "Summary\nSecurity leader with RMF experience.",
                encoding="utf-8",
            )

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = atsim.main(["verify-diffs", str(app_dir), "--diffs", str(artifacts_dir / "missing.json")])

            self.assertEqual(result, 1)
            self.assertIn("JSON file not found", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
