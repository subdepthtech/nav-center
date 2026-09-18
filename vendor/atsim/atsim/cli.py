#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree


TOOL_VERSION = "0.1.0"
PACKAGE_ROOT = Path(__file__).resolve().parent
DEFAULT_JOB_HUNT_ROOT = Path(os.environ.get("ATSIM_JOB_HUNT_ROOT", "/Users/tucker/projects/job-hunt")).expanduser()
REPO_ROOT = DEFAULT_JOB_HUNT_ROOT
DEFAULT_MASTER_RESUME = REPO_ROOT / "master-resumes" / "master_primary.yaml"
DEFAULT_SUGGESTIONS_JSON = "ats-suggestions.json"
DEFAULT_SUGGESTIONS_MD = "ats-suggestions.md"
DEFAULT_FIX_PROMPT = "ats-fix-prompt.md"
DEFAULT_RAW_DIFFS_JSON = "ats-llm-diffs.raw.json"
DEFAULT_VERIFIED_DIFFS_JSON = "ats-verified-diffs.json"
DEFAULT_VERIFIED_DIFFS_MD = "ats-verified-diffs.md"
DEFAULT_OPENCODE_MODEL = "zai-coding-plan/glm-5.1"
DEFAULT_OPENCODE_AGENT = "plan"
DEFAULT_OPENCODE_SDK_RUNNER = Path(
  os.environ.get(
    "ATSIM_OPENCODE_SDK_RUNNER",
    str(PACKAGE_ROOT / "scripts" / "atsim_opencode_sdk.mjs"),
  )
).expanduser()

ALLOWED_EDIT_PATHS = [
  "summary",
  "skills",
  "professional_experience.bullets",
  "projects.bullets",
]

BLOCKED_EDIT_FIELDS = [
  "name",
  "contact details",
  "company names",
  "job titles",
  "dates",
  "education",
  "certifications not already supported by master-resumes/master_primary.yaml",
]

STANDARD_SECTIONS = {
  "summary",
  "profile",
  "professional summary",
  "experience",
  "work experience",
  "professional experience",
  "employment history",
  "skills",
  "technical skills",
  "core competencies",
  "education",
  "projects",
  "certifications",
  "certificates",
  "awards",
  "publications",
  "volunteer",
}

DEFAULT_SKILLS = {
  # Languages and software engineering
  "python",
  "javascript",
  "typescript",
  "java",
  "c++",
  "c#",
  "go",
  "rust",
  "ruby",
  "php",
  "sql",
  "bash",
  "powershell",
  "react",
  "next.js",
  "node.js",
  "express",
  "django",
  "flask",
  "fastapi",
  "rest api",
  "rest apis",
  "graphql",
  "microservices",
  "api",
  # Data, AI, and analytics
  "pandas",
  "numpy",
  "scikit-learn",
  "tensorflow",
  "pytorch",
  "machine learning",
  "deep learning",
  "nlp",
  "data engineering",
  "etl",
  "airflow",
  "spark",
  "analytics",
  "ai",
  "artificial intelligence",
  "llm",
  "generative ai",
  "prompt engineering",
  "ai governance",
  # Cloud, DevOps, and platforms
  "aws",
  "azure",
  "gcp",
  "docker",
  "kubernetes",
  "terraform",
  "jenkins",
  "github actions",
  "gitlab ci",
  "ci/cd",
  "linux",
  "windows",
  "macos",
  # Databases
  "postgresql",
  "postgres",
  "mysql",
  "mongodb",
  "redis",
  "elasticsearch",
  "snowflake",
  "bigquery",
  "dynamodb",
  # Cybersecurity, GRC, and federal security
  "rmf",
  "nist",
  "nist 800-53",
  "nist 800-171",
  "disa stig",
  "stig",
  "ato",
  "poa&m",
  "poam",
  "fedramp",
  "cmmc",
  "cissp",
  "security+",
  "ts/sci",
  "clearance",
  "incident response",
  "vulnerability management",
  "continuous monitoring",
  "risk management",
  "governance",
  "grc",
  "audit",
  "compliance",
  "siem",
  "splunk",
  "iam",
  "zero trust",
  "oauth",
  "saml",
  "okta",
  "identity",
  "cloud security",
  "security operations",
  "soc",
  "threat intelligence",
  "executive briefing",
  "stakeholder management",
  # Product and business
  "agile",
  "scrum",
  "roadmap",
  "a/b testing",
  "salesforce",
  "hubspot",
}

AMBIGUOUS_SKILL_PATTERNS = {
  "ai": re.compile(r"(?<![a-zA-Z0-9+#./-])(?:AI|A\.I\.)(?![a-zA-Z0-9+#./-])"),
  "api": re.compile(r"(?<![a-zA-Z0-9+#./-])APIs?(?![a-zA-Z0-9+#./-])"),
  "go": re.compile(r"(?<![a-zA-Z0-9+#./-])(?:Go|Golang)(?![a-zA-Z0-9+#./-])"),
  "iam": re.compile(r"(?<![a-zA-Z0-9+#./-])IAM(?![a-zA-Z0-9+#./-])"),
  "soc": re.compile(r"(?<![a-zA-Z0-9+#./-])SOC(?![a-zA-Z0-9+#./-])"),
}

STOP_WORDS = {
  "a",
  "an",
  "and",
  "are",
  "as",
  "at",
  "be",
  "by",
  "for",
  "from",
  "has",
  "have",
  "in",
  "is",
  "it",
  "of",
  "on",
  "or",
  "our",
  "that",
  "the",
  "their",
  "this",
  "to",
  "with",
  "will",
  "you",
  "your",
}


@dataclass(frozen=True)
class ResumeSource:
  input_path: Path
  text_path: Path
  text: str
  reader: str
  application_dir: Path | None = None
  default_jd_path: Path | None = None


@dataclass(frozen=True)
class SuggestionOutputs:
  json_path: Path | None
  markdown_path: Path | None
  prompt_path: Path | None


@dataclass(frozen=True)
class VerifyOutputs:
  json_path: Path | None
  markdown_path: Path | None


@dataclass(frozen=True)
class DraftOutputs:
  json_path: Path | None


def json_print(payload: object) -> None:
  print(json.dumps(payload, indent=2))


def normalize(text: str) -> str:
  text = html.unescape(text)
  replacements = {
    "\u00a0": " ",
    "\u2010": "-",
    "\u2011": "-",
    "\u2012": "-",
    "\u2013": "-",
    "\u2014": "-",
    "\u2022": "-",
    "\u25cf": "-",
  }
  for old, new in replacements.items():
    text = text.replace(old, new)
  text = re.sub(r"[ \t]+", " ", text)
  text = re.sub(r"\n{3,}", "\n\n", text)
  return text.strip()


def strip_markdown_frontmatter(text: str) -> str:
  if not text.startswith("---"):
    return text
  match = re.match(r"^---\s*\n.*?\n---\s*\n?", text, re.S)
  if not match:
    return text
  return text[match.end():]


def lower_clean(text: str) -> str:
  return normalize(text).lower()


def command_output(command: str, args: list[str]) -> str | None:
  if shutil.which(command) is None:
    return None
  result = subprocess.run(
    [command, *args],
    cwd=REPO_ROOT,
    capture_output=True,
    encoding="utf-8",
    errors="ignore",
    check=False,
  )
  if result.returncode != 0:
    return None
  return result.stdout


def read_pdf(path: Path) -> tuple[str, str]:
  pdftotext = command_output("pdftotext", ["-layout", str(path), "-"])
  if pdftotext and pdftotext.strip():
    return pdftotext, "pdftotext -layout"

  try:
    from pypdf import PdfReader  # type: ignore
  except ImportError as error:
    raise RuntimeError(
      "PDF text extraction needs pdftotext on PATH or pypdf installed. "
      "Run `python3 -m pip install -r requirements.txt` for the optional Python reader."
    ) from error

  reader = PdfReader(str(path))
  chunks: list[str] = []
  for page in reader.pages:
    try:
      chunks.append(page.extract_text(extraction_mode="layout") or "")
    except TypeError:
      chunks.append(page.extract_text() or "")
  return "\n".join(chunks), "pypdf"


def read_docx(path: Path) -> tuple[str, str]:
  pandoc = command_output("pandoc", [str(path), "-t", "plain"])
  if pandoc and pandoc.strip():
    return pandoc, "pandoc plain"

  try:
    with zipfile.ZipFile(path) as archive:
      xml = archive.read("word/document.xml")
  except (KeyError, zipfile.BadZipFile) as error:
    raise RuntimeError(f"Could not read DOCX XML: {path}") from error

  root = ElementTree.fromstring(xml)
  namespace = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
  paragraphs: list[str] = []
  for para in root.findall(".//w:p", namespace):
    text = "".join(node.text or "" for node in para.findall(".//w:t", namespace)).strip()
    if text:
      paragraphs.append(text)
  return "\n".join(paragraphs), "docx xml"


def read_text_file(path: Path) -> tuple[str, str]:
  suffix = path.suffix.lower()
  if suffix == ".pdf":
    return read_pdf(path)
  if suffix == ".docx":
    return read_docx(path)
  if suffix in {".txt", ".md", ".markdown"}:
    text = path.read_text(encoding="utf-8", errors="ignore")
    if suffix in {".md", ".markdown"}:
      text = strip_markdown_frontmatter(text)
    return text, "plain text"
  raise RuntimeError(f"Unsupported resume file type: {suffix}")


def application_resume_candidates(app_dir: Path) -> list[Path]:
  artifacts = app_dir / "artifacts"
  candidates: list[Path] = []
  if artifacts.exists():
    candidates.extend(sorted(artifacts.glob("Resume_*.docx.txt")))
    candidates.extend(sorted(artifacts.glob("Resume_*.pdf.txt")))
    candidates.extend(sorted(artifacts.glob("Resume_*.txt")))
  candidates.extend(sorted(app_dir.glob("Resume_*.md")))
  return list(dict.fromkeys(candidates))


def resolve_resume_source(input_path: Path) -> ResumeSource:
  path = input_path.expanduser().resolve()
  if path.is_dir():
    candidates = application_resume_candidates(path)
    if not candidates:
      raise RuntimeError(f"No Resume_* source or extraction text found in application package: {path}")
    text_path = candidates[0]
    text, reader = read_text_file(text_path)
    posting = path / "posting.md"
    return ResumeSource(
      input_path=path,
      text_path=text_path,
      text=normalize(text),
      reader=f"application package ({reader})",
      application_dir=path,
      default_jd_path=posting if posting.exists() else None,
    )

  text, reader = read_text_file(path)
  return ResumeSource(input_path=path, text_path=path, text=normalize(text), reader=reader)


def read_jd(path: Path) -> str:
  text = path.expanduser().read_text(encoding="utf-8", errors="ignore")
  if path.suffix.lower() in {".md", ".markdown"}:
    text = strip_markdown_frontmatter(text)
  return normalize(text)


def heading_key(line: str) -> str:
  line = line.strip()
  line = re.sub(r"^#{1,6}\s*", "", line)
  line = re.sub(r"^\*{1,2}(.+?)\*{1,2}$", r"\1", line)
  line = line.strip(":-* ")
  line = re.sub(r"\s+", " ", line)
  return line.lower()


def extract_contact(text: str) -> dict[str, str | None]:
  email = re.search(r"[\w.\-+]+@[\w.\-]+\.\w+", text)
  phone = re.search(r"(?:(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4})", text)
  linkedin = re.search(r"(?:https?://)?(?:www\.)?(linkedin\.com/in/[A-Za-z0-9_\-/%]+)", text, re.I)
  github = re.search(r"(?:https?://)?(?:www\.)?(github\.com/[A-Za-z0-9_\-]+)", text, re.I)
  return {
    "email": email.group(0) if email else None,
    "phone": phone.group(0) if phone else None,
    "linkedin": linkedin.group(1) if linkedin else None,
    "github": github.group(1) if github else None,
  }


def detect_sections(text: str) -> list[str]:
  found: set[str] = set()
  for line in text.splitlines():
    compact = heading_key(line)
    if compact in STANDARD_SECTIONS:
      found.add(compact)

  body = "\n" + lower_clean(text) + "\n"
  for section in STANDARD_SECTIONS:
    if re.search(rf"\n\s*(?:#+\s*)?{re.escape(section)}\s*:?\s*\n", body):
      found.add(section)
  return sorted(found)


def load_skills(skills_file: Path | None) -> set[str]:
  skills = set(DEFAULT_SKILLS)
  if skills_file:
    raw = skills_file.expanduser().read_text(encoding="utf-8", errors="ignore")
    for line in raw.splitlines():
      line = line.strip().lower()
      if line and not line.startswith("#"):
        skills.add(line)
  return skills


def skill_pattern(skill: str) -> re.Pattern[str]:
  escaped = re.escape(skill.lower()).replace(r"\ ", r"\s+")
  return re.compile(rf"(?<![a-z0-9+#/-]){escaped}(?![a-z0-9+#/-])", re.I)


def skill_found(text: str, skill: str) -> bool:
  ambiguous = AMBIGUOUS_SKILL_PATTERNS.get(skill)
  if ambiguous:
    return bool(ambiguous.search(text))
  return bool(skill_pattern(skill).search(lower_clean(text)))


def extract_relevant_skills(text: str, skill_bank: set[str]) -> set[str]:
  found = set()
  for skill in skill_bank:
    if skill_found(text, skill):
      found.add(skill)
  return found


def fuzzy_ratio(a: str, b: str) -> float:
  from difflib import SequenceMatcher

  return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def fuzzy_skill_match(skill: str, resume_text: str, threshold: float = 0.9) -> bool:
  if skill in AMBIGUOUS_SKILL_PATTERNS:
    return skill_found(resume_text, skill)

  body = lower_clean(resume_text)
  if skill_pattern(skill).search(body):
    return True

  words = re.findall(r"[a-zA-Z0-9+#./-]+", body)
  skill_words = re.findall(r"[a-zA-Z0-9+#./-]+", skill.lower())
  window_size = max(1, len(skill_words) + 2)
  for index in range(0, max(1, len(words) - window_size + 1)):
    window = " ".join(words[index:index + window_size])
    if fuzzy_ratio(skill, window) >= threshold:
      return True
  return False


def keyword_match(resume_text: str, jd_text: str, skill_bank: set[str]) -> dict[str, object]:
  jd_skills = extract_relevant_skills(jd_text, skill_bank)
  matched = set()
  missing = set()
  for skill in jd_skills:
    if fuzzy_skill_match(skill, resume_text):
      matched.add(skill)
    else:
      missing.add(skill)
  coverage = len(matched) / len(jd_skills) if jd_skills else 0.0
  return {
    "jd_skills": sorted(jd_skills),
    "matched": sorted(matched),
    "missing": sorted(missing),
    "coverage": round(coverage, 4),
  }


def tokenize(text: str) -> list[str]:
  tokens = [
    token
    for token in re.findall(r"[a-zA-Z][a-zA-Z0-9+#./-]*", lower_clean(text))
    if len(token) > 1 and token not in STOP_WORDS
  ]
  bigrams = [f"{tokens[index]} {tokens[index + 1]}" for index in range(len(tokens) - 1)]
  return tokens + bigrams


def semantic_similarity(resume_text: str, jd_text: str) -> float:
  documents = [tokenize(resume_text), tokenize(jd_text)]
  if not documents[0] or not documents[1]:
    return 0.0

  vocab = sorted(set(documents[0]) | set(documents[1]))
  doc_count = len(documents)
  document_frequency = {
    term: sum(1 for document in documents if term in document)
    for term in vocab
  }

  vectors: list[list[float]] = []
  for document in documents:
    counts = Counter(document)
    total = sum(counts.values()) or 1
    vector = []
    for term in vocab:
      tf = counts[term] / total
      idf = math.log((1 + doc_count) / (1 + document_frequency[term])) + 1
      vector.append(tf * idf)
    vectors.append(vector)

  dot = sum(left * right for left, right in zip(vectors[0], vectors[1]))
  left_norm = math.sqrt(sum(value * value for value in vectors[0]))
  right_norm = math.sqrt(sum(value * value for value in vectors[1]))
  if left_norm == 0 or right_norm == 0:
    return 0.0
  return round(dot / (left_norm * right_norm), 4)


def detect_date_formats(text: str) -> dict[str, object]:
  month_year = re.findall(
    r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{4}\b",
    text,
    re.I,
  )
  numeric_month_year = re.findall(r"\b\d{1,2}/\d{4}\b", text)
  year_month = re.findall(r"\b\d{4}[-/]\d{1,2}\b", text)
  has_mix = sum(bool(group) for group in (month_year, numeric_month_year, year_month)) > 1
  return {
    "month_year_count": len(month_year),
    "numeric_month_year_count": len(numeric_month_year),
    "year_month_count": len(year_month),
    "has_inconsistent_or_risky_dates": bool(year_month) or has_mix,
  }


def bullet_lines(text: str) -> list[str]:
  return [line for line in text.splitlines() if re.match(r"^\s*(?:[-*]|\d+[.)])\s+", line)]


def repeated_short_lines(text: str) -> list[str]:
  candidates = []
  for line in text.splitlines():
    stripped = line.strip()
    if not 3 <= len(stripped) <= 80:
      continue
    if re.fullmatch(r"[-*_]{3,}", stripped):
      continue
    candidates.append(stripped)
  counts = Counter(candidates)
  return sorted(line for line, count in counts.items() if count >= 3)


def formatting_warnings(path: Path, text: str, sections: list[str], jd_text: str | None = None) -> list[str]:
  warnings: list[str] = []
  suffixes = "".join(path.suffixes).lower()
  contact = extract_contact(text)
  date_info = detect_date_formats(text)

  if ".pdf" in suffixes and len(text.strip()) < 500:
    warnings.append("Very little text extracted from PDF; it may be scanned or image-based.")
  if len(text.strip()) < 800:
    warnings.append("Extracted resume text is short; confirm the full resume parsed.")
  if len(sections) < 3:
    warnings.append("Few standard resume section headings detected.")
  if not contact["email"]:
    warnings.append("No email address detected.")
  if not contact["phone"]:
    warnings.append("No phone number detected.")
  if "certifications" not in sections and jd_text and re.search(r"\b(?:certification|cissp|security\+|certificate)\b", jd_text, re.I):
    warnings.append("No Certifications section found, but the job description appears to mention certifications.")
  if date_info["has_inconsistent_or_risky_dates"]:
    warnings.append("Inconsistent or risky date formats detected; prefer Month YYYY.")

  lines = text.splitlines()
  wide_gap_lines = [line for line in lines if re.search(r"\S\s{8,}\S", line)]
  if len(wide_gap_lines) >= 5:
    warnings.append("Possible multi-column or table-like layout detected from wide spacing.")

  markdown_table_lines = [line for line in lines if re.match(r"^\s*\|.+\|\s*$", line)]
  if len(markdown_table_lines) >= 2:
    warnings.append("Table-like markdown detected; tables are a parsing risk.")

  if re.search(r"!\[[^\]]*]\([^)]+\)", text):
    warnings.append("Image or logo markdown detected; images are a parsing risk.")
  if re.search(r"\[[^\]]+]\((?:https?://|mailto:)[^)]+\)", text):
    warnings.append("Markdown hyperlinks detected; make sure critical contact or skill text is visible as plain text.")

  unusual_bullets = re.findall(r"[◆◇■□▪▫→✓★]", text)
  if len(unusual_bullets) >= 3:
    warnings.append("Unusual bullet symbols detected; simple bullets are safer.")

  repeats = repeated_short_lines(text)
  if repeats:
    warnings.append("Repeated short lines detected; check for header or footer text in extracted output.")

  if not bullet_lines(text):
    warnings.append("No standard resume bullets detected.")

  return warnings


def parseability_score(text: str, contact: dict[str, str | None], sections: list[str], warnings: list[str]) -> int:
  score = 0
  length = len(text.strip())
  if length >= 1500:
    score += 8
  elif length >= 800:
    score += 6
  elif length >= 400:
    score += 4

  if contact["email"]:
    score += 4
  if contact["phone"]:
    score += 4
  if contact["linkedin"]:
    score += 2

  score += min(10, len(sections) * 2)
  if bullet_lines(text):
    score += 2
  if not warnings:
    score += 2
  elif len(warnings) <= 2:
    score += 1
  return min(score, 30)


def format_score(warnings: list[str]) -> int:
  heavy_patterns = ("scanned", "multi-column", "table", "No email", "No phone")
  penalty = 0
  for warning in warnings:
    penalty += 2 if any(pattern in warning for pattern in heavy_patterns) else 1
  return max(0, 10 - penalty)


def read_master_resume(path: Path) -> str:
  master_path = path.expanduser().resolve()
  if not master_path.exists():
    raise RuntimeError(f"Master resume not found: {master_path}")
  return normalize(master_path.read_text(encoding="utf-8", errors="ignore"))


def clean_evidence_line(line: str) -> str:
  line = line.strip()
  line = re.sub(r"^[-*]\s*", "", line)
  line = re.sub(r"^\w+:\s*", "", line)
  line = line.strip(" \"'")
  return line


def find_master_evidence(master_text: str, skill: str, limit: int = 3) -> list[str]:
  evidence = []
  for line in master_text.splitlines():
    cleaned = clean_evidence_line(line)
    if cleaned and skill_found(cleaned, skill):
      evidence.append(cleaned)
    if len(evidence) >= limit:
      break
  return evidence


def formatting_recommendation(warning: str) -> tuple[str, str, list[str]]:
  warning_lower = warning.lower()
  if "scanned" in warning_lower or "very little text" in warning_lower:
    return (
      "high",
      "Regenerate the resume from source markdown and verify the PDF/DOCX text extraction files are readable.",
      ["source markdown", "generated artifacts"],
    )
  if "no email" in warning_lower or "no phone" in warning_lower:
    return (
      "high",
      "Make sure the contact header renders as plain text in both DOCX and PDF extraction output.",
      ["contact header"],
    )
  if "multi-column" in warning_lower or "table" in warning_lower:
    return (
      "medium",
      "Replace table-like or column-like layout with simple single-column text and standard bullets.",
      ["skills", "professional_experience.bullets", "projects.bullets"],
    )
  if "section" in warning_lower:
    return (
      "medium",
      "Use standard resume section headings such as Summary, Skills, Professional Experience, Education, Certifications, and Awards.",
      ["section headings"],
    )
  if "date formats" in warning_lower:
    return (
      "medium",
      "Normalize visible resume dates to Month YYYY format without changing the actual timeline.",
      ["professional_experience.bullets", "projects.bullets"],
    )
  if "bullets" in warning_lower:
    return (
      "medium",
      "Use simple hyphen bullets for resume accomplishments so ATS text extraction remains predictable.",
      ["professional_experience.bullets", "projects.bullets"],
    )
  return (
    "low",
    "Review the extracted text and adjust only the visible formatting needed to remove this parser risk.",
    ["source markdown"],
  )


def build_formatting_suggestions(warnings: list[str]) -> list[dict[str, object]]:
  suggestions = []
  for index, warning in enumerate(warnings, start=1):
    severity, recommendation, allowed_paths = formatting_recommendation(warning)
    suggestions.append(
      {
        "id": f"fmt-{index:03d}",
        "severity": severity,
        "category": "formatting",
        "evidence": warning,
        "recommendation": recommendation,
        "allowed_paths": allowed_paths,
        "master_supported": None,
        "blocked_reason": None,
        "master_evidence": [],
      }
    )
  return suggestions


def build_keyword_suggestions(report: dict[str, object], master_text: str) -> list[dict[str, object]]:
  keywords = report.get("keywords")
  if not isinstance(keywords, dict):
    return []

  missing = keywords.get("missing", [])
  if not isinstance(missing, list):
    return []

  suggestions = []
  for index, raw_skill in enumerate(missing, start=1):
    skill = str(raw_skill)
    evidence = find_master_evidence(master_text, skill)
    supported = bool(evidence) or skill_found(master_text, skill)
    if supported:
      recommendation = (
        f"Consider weaving `{skill}` into an existing summary, skills, experience, or project line "
        "only where the current resume already supports the claim."
      )
      blocked_reason = None
      severity = "medium"
    else:
      recommendation = (
        f"Do not add `{skill}` unless new source evidence is added to master-resumes/master_primary.yaml first."
      )
      blocked_reason = "Missing from master-resumes/master_primary.yaml; adding it would risk an unsupported claim."
      severity = "low"

    suggestions.append(
      {
        "id": f"kw-{index:03d}",
        "severity": severity,
        "category": "keyword",
        "evidence": f"`{skill}` appears in the job description but was not detected in the resume text.",
        "recommendation": recommendation,
        "allowed_paths": ALLOWED_EDIT_PATHS if supported else [],
        "master_supported": supported,
        "blocked_reason": blocked_reason,
        "master_evidence": evidence,
      }
    )
  return suggestions


def build_suggestion_bundle(
  resume_input: Path,
  jd_path: Path | None = None,
  skills_file: Path | None = None,
  master_path: Path = DEFAULT_MASTER_RESUME,
) -> dict[str, object]:
  report = build_report(resume_input, jd_path, skills_file)
  source = resolve_resume_source(resume_input)
  input_info = report["input"]
  assert isinstance(input_info, dict)
  jd_text = None
  if input_info.get("job_description"):
    jd_text = read_jd(Path(str(input_info["job_description"])))
  master_text = read_master_resume(master_path)
  warnings = report.get("warnings", [])
  if not isinstance(warnings, list):
    warnings = []

  suggestions = [
    *build_formatting_suggestions([str(warning) for warning in warnings]),
    *build_keyword_suggestions(report, master_text),
  ]

  supported_count = sum(1 for item in suggestions if item.get("master_supported") is True)
  blocked_count = sum(1 for item in suggestions if item.get("blocked_reason"))
  return {
    "input": input_info,
    "scores": report["scores"],
    "suggestion_summary": {
      "total": len(suggestions),
      "formatting": sum(1 for item in suggestions if item["category"] == "formatting"),
      "keyword": sum(1 for item in suggestions if item["category"] == "keyword"),
      "master_supported_keywords": supported_count,
      "blocked_keywords": blocked_count,
    },
    "allowed_edit_paths": ALLOWED_EDIT_PATHS,
    "blocked_edit_fields": BLOCKED_EDIT_FIELDS,
    "prompt_context": {
      "resume_text_source": str(source.text_path),
      "resume_text": source.text,
      "job_description_text": jd_text,
    },
    "suggestions": suggestions,
    "note": (
      "These are deterministic ATS fix suggestions. They are not automatic edits, and they do not "
      "claim any specific ATS will pass or fail the resume."
    ),
  }


def render_suggestions_markdown(bundle: dict[str, object]) -> str:
  input_info = bundle["input"]
  scores = bundle["scores"]
  summary = bundle["suggestion_summary"]
  suggestions = bundle["suggestions"]
  assert isinstance(input_info, dict)
  assert isinstance(scores, dict)
  assert isinstance(summary, dict)
  assert isinstance(suggestions, list)

  lines = [
    "# ATS Fix Suggestions",
    "",
    f"- Resume source: `{input_info.get('text_source')}`",
    f"- Job description: `{input_info.get('job_description')}`",
    f"- Simulation score: `{scores.get('overall')}`",
    f"- Suggestions: `{summary.get('total')}` total, `{summary.get('blocked_keywords')}` blocked keyword gaps",
    "",
    "## Safe Formatting Fixes",
    "",
  ]

  formatting_items = [item for item in suggestions if isinstance(item, dict) and item.get("category") == "formatting"]
  if formatting_items:
    for item in formatting_items:
      lines.extend(
        [
          f"### {item['id']} ({item['severity']})",
          "",
          f"- Evidence: {item['evidence']}",
          f"- Recommendation: {item['recommendation']}",
          f"- Allowed paths: {', '.join(item['allowed_paths'])}",  # type: ignore[arg-type]
          "",
        ]
      )
  else:
    lines.extend(["No formatting suggestions.", ""])

  lines.extend(["## Supported Keyword Opportunities", ""])
  supported_keywords = [
    item
    for item in suggestions
    if isinstance(item, dict) and item.get("category") == "keyword" and item.get("master_supported") is True
  ]
  if supported_keywords:
    for item in supported_keywords:
      evidence = item.get("master_evidence", [])
      evidence_text = "; ".join(evidence) if isinstance(evidence, list) and evidence else "Matched in master resume text."
      lines.extend(
        [
          f"### {item['id']} ({item['severity']})",
          "",
          f"- Evidence: {item['evidence']}",
          f"- Master evidence: {evidence_text}",
          f"- Recommendation: {item['recommendation']}",
          "",
        ]
      )
  else:
    lines.extend(["No supported missing keyword opportunities.", ""])

  lines.extend(["## Blocked Or Needs Evidence", ""])
  blocked_keywords = [
    item
    for item in suggestions
    if isinstance(item, dict) and item.get("category") == "keyword" and item.get("blocked_reason")
  ]
  if blocked_keywords:
    for item in blocked_keywords:
      lines.extend(
        [
          f"### {item['id']} ({item['severity']})",
          "",
          f"- Evidence: {item['evidence']}",
          f"- Blocked reason: {item['blocked_reason']}",
          f"- Recommendation: {item['recommendation']}",
          "",
        ]
      )
  else:
    lines.extend(["No blocked keyword gaps.", ""])

  lines.extend(
    [
      "## Guardrail",
      "",
      str(bundle["note"]),
      "",
    ]
  )
  return "\n".join(lines)


def render_fix_prompt(bundle: dict[str, object]) -> str:
  prompt_payload = {
    "task": "Suggest guarded resume edits as JSON diffs only.",
    "input": bundle["input"],
    "allowed_edit_paths": bundle["allowed_edit_paths"],
    "blocked_edit_fields": bundle["blocked_edit_fields"],
    "rules": [
      "Do not invent skills, tools, metrics, certifications, companies, titles, dates, or education.",
      "Only suggest changes supported by master_evidence.",
      "Each diff must include the exact original text and a replacement.",
      "If no safe edit exists, return an empty diffs list.",
    ],
    "required_output_schema": {
      "diffs": [
        {
          "suggestion_id": "kw-001",
          "path_hint": "summary",
          "original": "exact original text",
          "replacement": "safe replacement text",
          "reason": "why this helps the ATS/JD alignment",
          "master_evidence": ["source evidence from master resume"],
        }
      ]
    },
    "ats_suggestions": bundle["suggestions"],
    "prompt_context": bundle["prompt_context"],
  }

  return "\n".join(
    [
      "# Guarded ATS Fix Prompt",
      "",
      "Use this prompt with Codex, an SDK agent, or another LLM to draft suggestions only.",
      "The LLM must return JSON diffs. Local verification must accept or reject every diff before any resume edit is made.",
      "",
      "```json",
      json.dumps(prompt_payload, indent=2),
      "```",
      "",
    ]
  )


def redact_resume_text_for_external_model(text: str) -> str:
  lines = text.splitlines()
  first_section_index = next(
    (index for index, line in enumerate(lines) if heading_key(line) in STANDARD_SECTIONS),
    None,
  )
  if first_section_index and first_section_index > 0:
    text = "\n".join(["[redacted resume header/contact details]", *lines[first_section_index:]])
  elif first_section_index is None:
    redacted_lines = list(lines)
    for index, line in enumerate(redacted_lines):
      if line.strip():
        redacted_lines[index] = "[redacted resume header/contact details]"
        break
    text = "\n".join(redacted_lines)

  contact = extract_contact(text)
  for field, value in contact.items():
    if value:
      text = text.replace(value, f"[redacted {field}]")
  return text


def path_label(value: object) -> object:
  if not isinstance(value, str) or not value:
    return value
  if "/" not in value:
    return value
  return Path(value).name or "[redacted path]"


def external_prompt_bundle(bundle: dict[str, object]) -> dict[str, object]:
  safe_bundle = json.loads(json.dumps(bundle))
  input_info = safe_bundle.get("input")
  if isinstance(input_info, dict):
    for key in ("resume", "text_source", "job_description", "skills_file"):
      input_info[key] = path_label(input_info.get(key))

  context = safe_bundle.get("prompt_context")
  if isinstance(context, dict):
    context["resume_text_source"] = path_label(context.get("resume_text_source"))
    resume_text = context.get("resume_text")
    if isinstance(resume_text, str):
      context["resume_text"] = redact_resume_text_for_external_model(resume_text)
      context["redaction_note"] = (
        "Header and contact details are redacted before provider-backed drafting. "
        "Do not propose edits to redacted text."
      )
  return safe_bundle


def render_draft_diff_prompt(bundle: dict[str, object]) -> str:
  safe_bundle = external_prompt_bundle(bundle)
  return "\n".join(
    [
      "You are drafting guarded ATS resume diffs for this repository.",
      "",
      "Return only a valid JSON object with a top-level `diffs` array. Do not include markdown fences, commentary, or edits outside the JSON.",
      "Prefer an empty `diffs` array over speculative edits.",
      "Every diff must preserve truthfulness, use exact original text from the resume extraction, and cite only master_evidence supplied by the prompt.",
      "Never add metrics, credentials, companies, titles, dates, education, contact details, or blocked keyword gaps.",
      "",
      render_fix_prompt(safe_bundle),
    ]
  )


def default_raw_diffs_output(resume_input: Path) -> Path | None:
  path = resume_input.expanduser().resolve()
  if path.is_dir():
    return path / "artifacts" / DEFAULT_RAW_DIFFS_JSON
  return None


def resolve_draft_outputs(args: argparse.Namespace) -> DraftOutputs:
  return DraftOutputs(json_path=args.out_json or default_raw_diffs_output(args.resume))


def default_suggestion_outputs(resume_input: Path) -> SuggestionOutputs:
  path = resume_input.expanduser().resolve()
  if path.is_dir():
    artifacts = path / "artifacts"
    return SuggestionOutputs(
      json_path=artifacts / DEFAULT_SUGGESTIONS_JSON,
      markdown_path=artifacts / DEFAULT_SUGGESTIONS_MD,
      prompt_path=artifacts / DEFAULT_FIX_PROMPT,
    )
  return SuggestionOutputs(json_path=None, markdown_path=None, prompt_path=None)


def resolve_suggestion_outputs(args: argparse.Namespace) -> SuggestionOutputs:
  defaults = default_suggestion_outputs(args.resume)
  return SuggestionOutputs(
    json_path=args.out_json or defaults.json_path,
    markdown_path=args.out_md or defaults.markdown_path,
    prompt_path=args.prompt_out or defaults.prompt_path,
  )


def default_verify_outputs(resume_input: Path) -> VerifyOutputs:
  path = resume_input.expanduser().resolve()
  if path.is_dir():
    artifacts = path / "artifacts"
    return VerifyOutputs(
      json_path=artifacts / DEFAULT_VERIFIED_DIFFS_JSON,
      markdown_path=artifacts / DEFAULT_VERIFIED_DIFFS_MD,
    )
  return VerifyOutputs(json_path=None, markdown_path=None)


def resolve_verify_outputs(args: argparse.Namespace) -> VerifyOutputs:
  defaults = default_verify_outputs(args.resume)
  return VerifyOutputs(
    json_path=args.out_json or defaults.json_path,
    markdown_path=args.out_md or defaults.markdown_path,
  )


def load_json_file(path: Path) -> object:
  resolved = path.expanduser()
  if not resolved.exists():
    raise RuntimeError(f"JSON file not found: {path}")
  try:
    return json.loads(resolved.read_text(encoding="utf-8"))
  except json.JSONDecodeError as error:
    raise RuntimeError(f"Invalid JSON in {path}: {error}") from error


def application_packages(applications_root: Path = REPO_ROOT / "applications") -> list[dict[str, object]]:
  root = applications_root.expanduser().resolve()
  if not root.exists():
    return []

  packages = []
  for path in sorted(root.iterdir(), key=lambda item: item.name, reverse=True):
    if not path.is_dir():
      continue
    artifacts = path / "artifacts"
    resume_sources = [candidate.name for candidate in application_resume_candidates(path)]
    packages.append(
      {
        "id": path.name,
        "path": str(path),
        "posting": str(path / "posting.md") if (path / "posting.md").exists() else None,
        "has_posting": (path / "posting.md").exists(),
        "resume_sources": resume_sources,
        "has_ats_report": (artifacts / "ats-report.json").exists(),
        "has_suggestions": (artifacts / DEFAULT_SUGGESTIONS_JSON).exists(),
        "has_raw_diffs": (artifacts / DEFAULT_RAW_DIFFS_JSON).exists(),
        "has_verified_diffs": (artifacts / DEFAULT_VERIFIED_DIFFS_JSON).exists(),
      }
    )
  return packages


def resolve_application_package(query: str, applications_root: Path = REPO_ROOT / "applications") -> dict[str, object]:
  raw = Path(query).expanduser()
  if raw.exists() and raw.is_dir():
    path = raw.resolve()
    return next(
      (
        item
        for item in application_packages(path.parent)
        if item["path"] == str(path)
      ),
      {
        "id": path.name,
        "path": str(path),
        "posting": str(path / "posting.md") if (path / "posting.md").exists() else None,
        "has_posting": (path / "posting.md").exists(),
        "resume_sources": [candidate.name for candidate in application_resume_candidates(path)],
        "has_ats_report": (path / "artifacts" / "ats-report.json").exists(),
        "has_suggestions": (path / "artifacts" / DEFAULT_SUGGESTIONS_JSON).exists(),
        "has_raw_diffs": (path / "artifacts" / DEFAULT_RAW_DIFFS_JSON).exists(),
        "has_verified_diffs": (path / "artifacts" / DEFAULT_VERIFIED_DIFFS_JSON).exists(),
      },
    )

  normalized_query = query.lower()
  packages = application_packages(applications_root)
  exact = [item for item in packages if str(item["id"]).lower() == normalized_query]
  if len(exact) == 1:
    return exact[0]

  matches = [item for item in packages if normalized_query in str(item["id"]).lower()]
  if len(matches) == 1:
    return matches[0]
  if not matches:
    raise RuntimeError(f"No application package matched: {query}")
  match_ids = ", ".join(str(item["id"]) for item in matches[:10])
  raise RuntimeError(f"Application query is ambiguous: {query}. Matches: {match_ids}")


def load_suggestion_bundle_for_draft(
  resume_input: Path,
  suggestions_path: Path | None,
  jd_path: Path | None,
  skills_file: Path | None,
  master_path: Path,
) -> dict[str, object]:
  has_source_override = bool(jd_path or skills_file or master_path.expanduser().resolve() != DEFAULT_MASTER_RESUME.resolve())
  if has_source_override and suggestions_path is None:
    return build_suggestion_bundle(resume_input, jd_path, skills_file, master_path)

  path = suggestions_path.expanduser().resolve() if suggestions_path else default_suggestion_outputs(resume_input).json_path
  if path and path.exists():
    payload = load_json_file(path)
    if not isinstance(payload, dict):
      raise RuntimeError(f"Suggestion file must be a JSON object: {path}")
    return payload
  return build_suggestion_bundle(resume_input, jd_path, skills_file, master_path)


def parse_json_payload_from_text(text: str) -> object:
  stripped = text.strip()
  if not stripped:
    raise RuntimeError("LLM runner returned empty output.")

  try:
    return json.loads(stripped)
  except json.JSONDecodeError:
    pass

  fenced_blocks = re.findall(r"```(?:json)?\s*(.*?)```", stripped, flags=re.S | re.I)
  for block in fenced_blocks:
    try:
      return json.loads(block.strip())
    except json.JSONDecodeError:
      continue

  starts: list[tuple[int, str, str]] = []
  for opener, closer in (("{", "}"), ("[", "]")):
    start = stripped.find(opener)
    if start != -1:
      starts.append((start, opener, closer))
  for first_start, opener, closer in sorted(starts):
    start = first_start
    while start != -1:
      depth = 0
      in_string = False
      escaped = False
      for index in range(start, len(stripped)):
        char = stripped[index]
        if in_string:
          if escaped:
            escaped = False
          elif char == "\\":
            escaped = True
          elif char == '"':
            in_string = False
          continue
        if char == '"':
          in_string = True
        elif char == opener:
          depth += 1
        elif char == closer:
          depth -= 1
          if depth == 0:
            candidate = stripped[start : index + 1]
            try:
              return json.loads(candidate)
            except json.JSONDecodeError:
              break
      start = stripped.find(opener, start + 1)

  raise RuntimeError("LLM runner output did not contain valid JSON.")


def run_opencode_draft(
  prompt: str,
  *,
  model: str,
  agent: str | None,
  opencode_bin: str,
  timeout: int,
) -> str:
  executable = shutil.which(opencode_bin)
  if executable is None:
    raise RuntimeError(f"OpenCode executable not found on PATH: {opencode_bin}")

  with tempfile.TemporaryDirectory(prefix="atsim-opencode-") as temp_dir:
    prompt_path = Path(temp_dir) / DEFAULT_FIX_PROMPT
    prompt_path.write_text(prompt, encoding="utf-8")
    command = [
      executable,
      "run",
      "--dir",
      str(REPO_ROOT),
      "--model",
      model,
      "--format",
      "default",
      "--title",
      "atsim draft-diffs",
      "--file",
      str(prompt_path),
    ]
    if agent:
      command.extend(["--agent", agent])
    command.append(
      "Read the attached guarded ATS fix prompt and return only the requested JSON object."
    )

    try:
      result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        timeout=timeout,
      )
    except subprocess.TimeoutExpired as error:
      raise RuntimeError(f"OpenCode draft timed out after {timeout} seconds.") from error

  if result.returncode != 0:
    details = (result.stderr or result.stdout or "").strip()
    if len(details) > 1000:
      details = details[:1000] + "..."
    raise RuntimeError(f"OpenCode draft failed with exit code {result.returncode}: {details}")
  return result.stdout


def run_opencode_sdk_draft(
  prompt: str,
  *,
  model: str,
  agent: str,
  sdk_runner: Path,
  timeout: int,
) -> str:
  runner = sdk_runner.expanduser().resolve()
  if not runner.exists():
    raise RuntimeError(f"OpenCode SDK runner not found: {runner}")

  with tempfile.TemporaryDirectory(prefix="atsim-opencode-sdk-") as temp_dir:
    prompt_path = Path(temp_dir) / DEFAULT_FIX_PROMPT
    prompt_path.write_text(prompt, encoding="utf-8")
    command = [
      "node",
      str(runner),
      "--prompt",
      str(prompt_path),
      "--directory",
      str(REPO_ROOT),
      "--model",
      model,
      "--agent",
      agent,
      "--timeout",
      str(timeout),
    ]
    try:
      result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        timeout=timeout + 10,
      )
    except subprocess.TimeoutExpired as error:
      raise RuntimeError(f"OpenCode SDK draft timed out after {timeout} seconds.") from error

  if result.returncode != 0:
    details = (result.stderr or result.stdout or "").strip()
    if len(details) > 1000:
      details = details[:1000] + "..."
    raise RuntimeError(f"OpenCode SDK draft failed with exit code {result.returncode}: {details}")
  return result.stdout


def draftable_suggestions(bundle: dict[str, object]) -> list[dict[str, object]]:
  suggestions = bundle.get("suggestions", [])
  if not isinstance(suggestions, list):
    return []
  return [
    item
    for item in suggestions
    if isinstance(item, dict) and not item.get("blocked_reason")
  ]


def draft_diffs_payload(args: argparse.Namespace) -> object:
  if args.backend not in {"opencode-sdk-zai", "opencode-zai", "opencode-cli-zai"}:
    raise RuntimeError(f"Unsupported draft backend: {args.backend}")

  bundle = load_suggestion_bundle_for_draft(
    args.resume,
    args.suggestions,
    args.jd,
    args.skills_file,
    args.master,
  )
  if not draftable_suggestions(bundle):
    return {"diffs": []}

  prompt = render_draft_diff_prompt(bundle)
  if args.backend == "opencode-cli-zai":
    raw_output = run_opencode_draft(
      prompt,
      model=args.model,
      agent=args.agent,
      opencode_bin=args.opencode_bin,
      timeout=args.timeout,
    )
  else:
    raw_output = run_opencode_sdk_draft(
      prompt,
      model=args.model,
      agent=args.agent,
      sdk_runner=args.sdk_runner,
      timeout=args.timeout,
    )
  payload = parse_json_payload_from_text(raw_output)
  extract_diffs(payload)
  return payload


def extract_diffs(payload: object) -> list[dict[str, object]]:
  if isinstance(payload, list):
    raw_diffs = payload
  elif isinstance(payload, dict) and isinstance(payload.get("diffs"), list):
    raw_diffs = payload["diffs"]
  else:
    raise RuntimeError("Diff file must be a JSON array or an object with a `diffs` array.")

  diffs = []
  for index, raw in enumerate(raw_diffs, start=1):
    if not isinstance(raw, dict):
      diffs.append({"_invalid": f"diff #{index} is not a JSON object"})
    else:
      diffs.append(raw)
  return diffs


def load_suggestion_bundle_for_verify(resume_input: Path, suggestions_path: Path | None) -> dict[str, object]:
  path = suggestions_path.expanduser().resolve() if suggestions_path else default_suggestion_outputs(resume_input).json_path
  if path and path.exists():
    payload = load_json_file(path)
    if not isinstance(payload, dict):
      raise RuntimeError(f"Suggestion file must be a JSON object: {path}")
    return payload
  return build_suggestion_bundle(resume_input)


def blocked_keywords_from_bundle(bundle: dict[str, object]) -> set[str]:
  blocked = set()
  suggestions = bundle.get("suggestions", [])
  if not isinstance(suggestions, list):
    return blocked
  for item in suggestions:
    if not isinstance(item, dict) or not item.get("blocked_reason"):
      continue
    evidence = str(item.get("evidence", ""))
    match = re.search(r"`([^`]+)`", evidence)
    if match:
      blocked.add(match.group(1).lower())
  return blocked


def referenced_suggestion(bundle: dict[str, object], suggestion_id: object) -> dict[str, object] | None:
  suggestions = bundle.get("suggestions", [])
  if not isinstance(suggestions, list):
    return None
  for item in suggestions:
    if isinstance(item, dict) and item.get("id") == suggestion_id:
      return item
  return None


def introduced_metrics(original: str, replacement: str) -> list[str]:
  metric_pattern = re.compile(
    r"\d+(?:\.\d+)?%|\d+(?:\.\d+)?x|\$\s?\d[\d,]*(?:\.\d+)?|\b\d{2,}\b"
  )
  original_metrics = set(metric_pattern.findall(original))
  replacement_metrics = set(metric_pattern.findall(replacement))
  return sorted(replacement_metrics - original_metrics)


def text_contains_blocked_field(text: str, resume_text: str = "") -> str | None:
  lowered = text.lower()
  contact = extract_contact(resume_text) if resume_text else {}
  for field in ("email", "phone", "linkedin", "github"):
    value = contact.get(field)
    if value and str(value).lower() in lowered:
      return "contact details"
  if re.search(r"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{4}\b", lowered):
    return "dates"
  if re.search(r"\b\d{4}\s*[-/]\s*(?:present|\d{4})\b", lowered):
    return "dates"
  if "master of science" in lowered or "bachelor of science" in lowered:
    return "education"
  return None


def normalize_edit_path(path_hint: object) -> str | None:
  hint = str(path_hint or "").lower()
  hint = hint.replace("-", "_").replace(" ", "_")
  if "summary" in hint:
    return "summary"
  if "skill" in hint:
    return "skills"
  if "project" in hint:
    return "projects.bullets"
  if "experience" in hint or "bullet" in hint:
    return "professional_experience.bullets"
  return None


def infer_text_path(resume_text: str, original: str) -> str | None:
  if not original.strip() or original not in resume_text:
    return None

  offset = resume_text.index(original)
  prefix = resume_text[:offset]
  line_index = prefix.count("\n")
  lines = resume_text.splitlines()
  current_section = "header"
  for index, line in enumerate(lines):
    key = heading_key(line)
    if key in {"summary", "professional summary", "profile"}:
      current_section = "summary"
    elif key in {"skills", "technical skills", "core competencies"}:
      current_section = "skills"
    elif key in {"experience", "work experience", "professional experience", "employment history"}:
      current_section = "professional_experience.bullets"
    elif key == "projects":
      current_section = "projects.bullets"
    elif key in {"education", "certifications", "certificates", "awards", "publications", "volunteer"}:
      current_section = key
    if index >= line_index:
      break
  return current_section


def suggestion_keyword(suggestion: dict[str, object]) -> str | None:
  evidence = str(suggestion.get("evidence", ""))
  match = re.search(r"`([^`]+)`", evidence)
  return match.group(1) if match else None


def validate_diff(
  diff: dict[str, object],
  resume_text: str,
  bundle: dict[str, object],
) -> dict[str, object]:
  reasons = []
  required_fields = ("suggestion_id", "path_hint", "original", "replacement", "reason", "master_evidence")
  for field in required_fields:
    if field not in diff:
      reasons.append(f"Missing required field: {field}")

  original = str(diff.get("original", ""))
  replacement = str(diff.get("replacement", ""))
  suggestion_id = diff.get("suggestion_id")
  path_hint = diff.get("path_hint")
  master_evidence = diff.get("master_evidence", [])
  referenced = referenced_suggestion(bundle, suggestion_id)

  if not original.strip():
    reasons.append("Original text is empty.")
  elif original not in resume_text:
    reasons.append("Original text was not found exactly in the resume extraction text.")
  elif resume_text.count(original) > 1:
    reasons.append("Original text appears more than once; path_hint is not enough for safe application.")

  if not replacement.strip():
    reasons.append("Replacement text is empty.")
  if replacement == original:
    reasons.append("Replacement text is unchanged.")

  for label, text in (("original", original), ("replacement", replacement)):
    blocked_field = text_contains_blocked_field(text, resume_text)
    if blocked_field:
      reasons.append(f"{label} touches blocked field: {blocked_field}.")

  hinted_path = normalize_edit_path(path_hint)
  if hinted_path is None:
    reasons.append("path_hint does not map to an allowed edit path.")
  inferred_path = infer_text_path(resume_text, original)
  if inferred_path is None:
    reasons.append("Could not infer original text section.")
  elif inferred_path not in ALLOWED_EDIT_PATHS:
    reasons.append(f"Original text is in blocked section: {inferred_path}.")

  metrics = introduced_metrics(original, replacement)
  if metrics:
    reasons.append(f"Replacement introduces unsupported metric(s): {', '.join(metrics)}.")

  blocked_keywords = blocked_keywords_from_bundle(bundle)
  for keyword in sorted(blocked_keywords):
    if skill_found(replacement, keyword) and not skill_found(original, keyword):
      reasons.append(f"Replacement introduces blocked keyword: {keyword}.")

  if referenced is None:
    reasons.append(f"Unknown suggestion_id: {suggestion_id}.")
  elif referenced.get("blocked_reason"):
    reasons.append(f"Referenced suggestion is blocked: {referenced.get('blocked_reason')}")
  else:
    allowed_paths = referenced.get("allowed_paths", ALLOWED_EDIT_PATHS)
    if not isinstance(allowed_paths, list):
      allowed_paths = ALLOWED_EDIT_PATHS
    normalized_allowed = {normalize_edit_path(path) or str(path) for path in allowed_paths}
    if hinted_path and hinted_path not in normalized_allowed:
      reasons.append(f"path_hint `{path_hint}` is not allowed for suggestion {suggestion_id}.")
    if inferred_path and inferred_path not in normalized_allowed:
      reasons.append(f"Original text section `{inferred_path}` is not allowed for suggestion {suggestion_id}.")

    keyword = suggestion_keyword(referenced)
    if referenced.get("category") == "keyword" and referenced.get("master_supported") is True and keyword:
      if not skill_found(replacement, keyword):
        reasons.append(f"Replacement does not include referenced supported keyword: {keyword}.")

  if not isinstance(master_evidence, list) or not master_evidence:
    reasons.append("master_evidence must be a non-empty list.")
  elif referenced is not None:
    allowed_evidence = {
      str(item)
      for item in referenced.get("master_evidence", [])
      if isinstance(item, str)
    }
    if allowed_evidence and not any(str(item) in allowed_evidence for item in master_evidence):
      reasons.append("master_evidence does not match the referenced suggestion evidence.")

  return {
    "diff": diff,
    "accepted": not reasons,
    "reasons": reasons,
  }


def verify_diffs_bundle(
  resume_input: Path,
  diffs_path: Path,
  suggestions_path: Path | None = None,
) -> dict[str, object]:
  source = resolve_resume_source(resume_input)
  suggestions = load_suggestion_bundle_for_verify(resume_input, suggestions_path)
  diffs = extract_diffs(load_json_file(diffs_path))
  results = [validate_diff(diff, source.text, suggestions) for diff in diffs]
  accepted = [item for item in results if item["accepted"]]
  rejected = [item for item in results if not item["accepted"]]
  return {
    "input": {
      "resume": str(source.input_path),
      "text_source": str(source.text_path),
      "diffs": str(diffs_path.expanduser().resolve()),
      "suggestions": str((suggestions_path.expanduser().resolve() if suggestions_path else default_suggestion_outputs(resume_input).json_path) or ""),
    },
    "summary": {
      "total": len(results),
      "accepted": len(accepted),
      "rejected": len(rejected),
    },
    "results": results,
    "note": "Accepted diffs are advisory only. This command verifies proposals; it does not edit resume files.",
  }


def render_verified_diffs_markdown(bundle: dict[str, object]) -> str:
  summary = bundle["summary"]
  results = bundle["results"]
  assert isinstance(summary, dict)
  assert isinstance(results, list)
  lines = [
    "# ATS Verified Diffs",
    "",
    f"- Total: `{summary.get('total')}`",
    f"- Accepted: `{summary.get('accepted')}`",
    f"- Rejected: `{summary.get('rejected')}`",
    "",
  ]
  for index, item in enumerate(results, start=1):
    if not isinstance(item, dict):
      continue
    diff = item.get("diff", {})
    if not isinstance(diff, dict):
      diff = {}
    status = "accepted" if item.get("accepted") else "rejected"
    lines.extend(
      [
        f"## Diff {index}: {status}",
        "",
        f"- Suggestion: `{diff.get('suggestion_id', '')}`",
        f"- Path hint: `{diff.get('path_hint', '')}`",
      ]
    )
    reasons = item.get("reasons", [])
    if isinstance(reasons, list) and reasons:
      lines.append("- Reasons:")
      for reason in reasons:
        lines.append(f"  - {reason}")
    lines.extend(["", "Original:", "", "```text", str(diff.get("original", "")), "```", "", "Replacement:", "", "```text", str(diff.get("replacement", "")), "```", ""])
  lines.extend(["## Guardrail", "", str(bundle["note"]), ""])
  return "\n".join(lines)


def build_report(
  resume_input: Path,
  jd_path: Path | None = None,
  skills_file: Path | None = None,
) -> dict[str, object]:
  source = resolve_resume_source(resume_input)
  effective_jd_path = jd_path.expanduser().resolve() if jd_path else source.default_jd_path
  jd_text = read_jd(effective_jd_path) if effective_jd_path else None

  sections = detect_sections(source.text)
  contact = extract_contact(source.text)
  warnings = formatting_warnings(source.text_path, source.text, sections, jd_text)
  parse_score = parseability_score(source.text, contact, sections, warnings)
  fmt_score = format_score(warnings)

  scores: dict[str, int | None] = {
    "parseability": parse_score,
    "formatting": fmt_score,
    "keyword": None,
    "semantic": None,
    "overall": parse_score + fmt_score,
  }
  keywords: dict[str, object] | None = None
  similarity: float | None = None

  if jd_text:
    skill_bank = load_skills(skills_file)
    keywords = keyword_match(source.text, jd_text, skill_bank)
    similarity = semantic_similarity(source.text, jd_text)
    keyword_score = round(float(keywords["coverage"]) * 40)
    semantic_score = round(similarity * 20)
    scores["keyword"] = keyword_score
    scores["semantic"] = semantic_score
    scores["overall"] = parse_score + fmt_score + keyword_score + semantic_score

  return {
    "input": {
      "resume": str(source.input_path),
      "text_source": str(source.text_path),
      "reader": source.reader,
      "job_description": str(effective_jd_path) if effective_jd_path else None,
      "skills_file": str(skills_file.expanduser().resolve()) if skills_file else None,
    },
    "contact": contact,
    "sections": sections,
    "text_length": len(source.text),
    "date_formats": detect_date_formats(source.text),
    "warnings": warnings,
    "scores": scores,
    "keywords": keywords,
    "semantic_similarity": similarity,
    "note": "This is a parseability and job-description alignment simulation, not an ATS pass/fail prediction.",
  }


def print_table_row(label: str, value: str, width: int = 22) -> None:
  print(f"{label:<{width}} {value:>12}")


def print_report(report: dict[str, object]) -> None:
  scores = report["scores"]
  assert isinstance(scores, dict)
  has_jd = scores.get("keyword") is not None
  denominator = 100 if has_jd else 40

  print("ATS Simulation Report")
  print("=" * 22)
  print(f"Resume source: {report['input']['text_source']}")  # type: ignore[index]
  if report["input"]["job_description"]:  # type: ignore[index]
    print(f"Job description: {report['input']['job_description']}")  # type: ignore[index]
  print()
  print_table_row("Simulation score:", f"{scores['overall']} / {denominator}")
  print_table_row("Parse confidence:", f"{scores['parseability']} / 30")
  print_table_row("Format safety:", f"{scores['formatting']} / 10")
  if has_jd:
    print_table_row("JD keyword coverage:", f"{scores['keyword']} / 40")
    print_table_row("Text similarity:", f"{scores['semantic']} / 20")

  print("\nDetected sections:")
  sections = report["sections"]
  assert isinstance(sections, list)
  print("  " + (", ".join(sections) if sections else "None"))

  keywords = report.get("keywords")
  if isinstance(keywords, dict):
    matched = keywords.get("matched", [])
    missing = keywords.get("missing", [])
    print("\nMatched skills:")
    print("  " + (", ".join(matched) if matched else "None"))  # type: ignore[arg-type]
    print("\nMissing likely JD skills:")
    print("  " + (", ".join(missing) if missing else "None"))  # type: ignore[arg-type]

  print("\nWarnings:")
  warnings = report["warnings"]
  assert isinstance(warnings, list)
  if warnings:
    for warning in warnings:
      print(f"  - {warning}")
  else:
    print("  None")

  print("\nNote:")
  print(f"  {report['note']}")


def command_doctor(args: argparse.Namespace) -> int:
  optional_tools = {
    "python3": shutil.which("python3"),
    "node": shutil.which("node"),
    "pandoc": shutil.which("pandoc"),
    "pdftotext": shutil.which("pdftotext"),
    "opencode": shutil.which("opencode"),
  }
  checks = {
    "repo_root": REPO_ROOT.exists(),
    "master_resume": DEFAULT_MASTER_RESUME.exists(),
    "applications_dir": (REPO_ROOT / "applications").exists(),
    "opencode_sdk_runner": DEFAULT_OPENCODE_SDK_RUNNER.exists(),
  }
  payload = {
    "tool": "atsim",
    "version": TOOL_VERSION,
    "ok": bool(checks["repo_root"] and checks["master_resume"] and checks["applications_dir"]),
    "checked_at": datetime.now(timezone.utc).isoformat(),
    "repo_root": str(REPO_ROOT),
    "install": {
      "path_command": shutil.which("atsim"),
      "expected_local_bin": str(Path.home() / ".local" / "bin" / "atsim"),
    },
    "auth": {
      "required": False,
      "source": "not_required",
      "available": False,
      "note": "Deterministic scan, parse, suggest, verify, and artifact reads run offline. draft-diffs may use a configured OpenCode backend.",
    },
    "config": {
      "required": False,
      "path": None,
    },
    "checks": checks,
    "tools": {
      name: {"available": path is not None, "path": path}
      for name, path in optional_tools.items()
    },
    "common_next_commands": [
      "atsim --json applications list --limit 10",
      "atsim --json scan applications/<application>",
      "atsim --json suggest applications/<application>",
    ],
  }
  if args.json:
    json_print(payload)
  else:
    print("atsim doctor")
    print("============")
    print(f"Version: {payload['version']}")
    print(f"Repo root: {REPO_ROOT}")
    print(f"Overall: {'ok' if payload['ok'] else 'needs setup'}")
    print("\nChecks:")
    for name, ok in checks.items():
      print(f"  - {name}: {'ok' if ok else 'missing'}")
    print("\nOptional tools:")
    for name, info in payload["tools"].items():  # type: ignore[union-attr]
      assert isinstance(info, dict)
      print(f"  - {name}: {info.get('path') or 'missing'}")
  return 0 if payload["ok"] else 1


def command_applications_list(args: argparse.Namespace) -> int:
  packages = application_packages(args.root)
  total = len(packages)
  if not args.all:
    packages = packages[: args.limit]
  payload = {
    "applications_root": str(args.root.expanduser().resolve()),
    "total": total,
    "limit": None if args.all else args.limit,
    "applications": packages,
  }
  if args.json:
    json_print(payload)
  else:
    for item in packages:
      status = []
      if item["has_posting"]:
        status.append("posting")
      if item["has_ats_report"]:
        status.append("ats-report")
      if item["has_suggestions"]:
        status.append("suggestions")
      print(f"{item['id']}  [{' '.join(status) or 'no status artifacts'}]")
  return 0


def command_applications_resolve(args: argparse.Namespace) -> int:
  package = resolve_application_package(args.query, args.root)
  if args.json:
    json_print(package)
  else:
    print(package["path"])
  return 0


def command_artifact_read(args: argparse.Namespace) -> int:
  payload = load_json_file(args.path)
  if args.json:
    json_print(payload)
  else:
    json_print(payload)
  return 0


def command_parse(args: argparse.Namespace) -> int:
  source = resolve_resume_source(args.resume)
  parsed = {
    "file": str(source.input_path),
    "text_source": str(source.text_path),
    "reader": source.reader,
    "contact": extract_contact(source.text),
    "sections": detect_sections(source.text),
    "text_length": len(source.text),
    "date_formats": detect_date_formats(source.text),
  }
  if args.json:
    json_print(parsed)
  else:
    for key, value in parsed.items():
      print(f"{key}: {value}")
  return 0


def command_scan(args: argparse.Namespace) -> int:
  report = build_report(args.resume, args.jd, args.skills_file)
  if args.json:
    json_print(report)
  else:
    print_report(report)
  if args.out:
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    if not args.json:
      print(f"\nWrote JSON report to {args.out}")
  return 0


def command_keywords(args: argparse.Namespace) -> int:
  jd_text = read_jd(args.jd)
  skills = sorted(extract_relevant_skills(jd_text, load_skills(args.skills_file)))
  if args.json:
    json_print({"job_description": str(args.jd), "skills": skills})
  else:
    for skill in skills:
      print(skill)
  return 0


def write_text_artifact(path: Path, content: str) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(content, encoding="utf-8")


def command_suggest(args: argparse.Namespace) -> int:
  bundle = build_suggestion_bundle(args.resume, args.jd, args.skills_file, args.master)
  markdown = render_suggestions_markdown(bundle)
  prompt = render_fix_prompt(bundle)
  outputs = resolve_suggestion_outputs(args)

  if outputs.json_path:
    write_text_artifact(outputs.json_path, json.dumps(bundle, indent=2))
  if outputs.markdown_path:
    write_text_artifact(outputs.markdown_path, markdown)
  if outputs.prompt_path:
    write_text_artifact(outputs.prompt_path, prompt)

  if args.json:
    json_print(bundle)
  else:
    print(markdown)

  written = [
    path
    for path in (outputs.json_path, outputs.markdown_path, outputs.prompt_path)
    if path is not None
  ]
  if written and not args.json:
    print("Wrote suggestion artifacts:")
    for path in written:
      print(f"  - {path}")
  return 0


def command_draft_diffs(args: argparse.Namespace) -> int:
  output = resolve_draft_outputs(args).json_path
  try:
    payload = draft_diffs_payload(args)
  except RuntimeError as error:
    failure_payload = {
      "diffs": [],
      "draft_error": {
        "backend": args.backend,
        "model": args.model,
        "message": str(error),
      },
    }
    if output:
      write_text_artifact(output, json.dumps(failure_payload, indent=2))
    raise

  diffs = extract_diffs(payload)

  if output:
    write_text_artifact(output, json.dumps(payload, indent=2))

  if args.json:
    json_print(payload)
  else:
    print("ATS Draft Diffs")
    print("===============")
    print(f"Backend: {args.backend}")
    print(f"Model: {args.model}")
    print(f"Diffs: {len(diffs)}")
    if output:
      print(f"Wrote raw diffs: {output}")
      verify_command = f"atsim verify-diffs {args.resume} --diffs {output}"
      if args.suggestions:
        verify_command += f" --suggestions {args.suggestions}"
      print()
      print("Next verification command:")
      print(f"  {verify_command}")
    else:
      print(json.dumps(payload, indent=2))
  return 0


def command_verify_diffs(args: argparse.Namespace) -> int:
  bundle = verify_diffs_bundle(args.resume, args.diffs, args.suggestions)
  markdown = render_verified_diffs_markdown(bundle)
  outputs = resolve_verify_outputs(args)

  if outputs.json_path:
    write_text_artifact(outputs.json_path, json.dumps(bundle, indent=2))
  if outputs.markdown_path:
    write_text_artifact(outputs.markdown_path, markdown)

  if args.json:
    json_print(bundle)
  else:
    print(markdown)

  written = [
    path
    for path in (outputs.json_path, outputs.markdown_path)
    if path is not None
  ]
  if written and not args.json:
    print("Wrote verified diff artifacts:")
    for path in written:
      print(f"  - {path}")
  return 0


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
    prog="atsim",
    description="ATS-style resume parser and job-description matcher.",
  )
  parser.add_argument("--json", action="store_true", default=False, help="Print machine-readable JSON output when supported.")
  parser.add_argument("--version", action="version", version=f"atsim {TOOL_VERSION}")
  subparsers = parser.add_subparsers(dest="command", required=True)

  doctor_cmd = subparsers.add_parser("doctor", help="Check local atsim setup, install state, and optional tooling.")
  doctor_cmd.set_defaults(func=command_doctor)

  applications_cmd = subparsers.add_parser("applications", help="Discover and resolve application package directories.")
  applications_subparsers = applications_cmd.add_subparsers(dest="applications_command", required=True)

  applications_list_cmd = applications_subparsers.add_parser("list", help="List recent application package IDs.")
  applications_list_cmd.add_argument("--root", type=Path, default=REPO_ROOT / "applications", help="Applications directory to scan.")
  applications_list_cmd.add_argument("--limit", type=int, default=20, help="Maximum packages to return unless --all is set.")
  applications_list_cmd.add_argument("--all", action="store_true", help="Return all packages.")
  applications_list_cmd.set_defaults(func=command_applications_list)

  applications_resolve_cmd = applications_subparsers.add_parser("resolve", help="Resolve an application package ID, substring, or path.")
  applications_resolve_cmd.add_argument("query", help="Application package ID, substring, or directory path.")
  applications_resolve_cmd.add_argument("--root", type=Path, default=REPO_ROOT / "applications", help="Applications directory to scan.")
  applications_resolve_cmd.set_defaults(func=command_applications_resolve)

  artifact_cmd = subparsers.add_parser("artifact", help="Read generated ATS JSON artifacts.")
  artifact_subparsers = artifact_cmd.add_subparsers(dest="artifact_command", required=True)

  artifact_read_cmd = artifact_subparsers.add_parser("read", help="Read and validate a JSON artifact file.")
  artifact_read_cmd.add_argument("path", type=Path, help="Path to a generated JSON artifact.")
  artifact_read_cmd.set_defaults(func=command_artifact_read)

  parse_cmd = subparsers.add_parser("parse", help="Parse a resume and show extracted fields.")
  parse_cmd.add_argument("resume", type=Path, help="Resume file or application package directory.")
  parse_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print JSON output.")
  parse_cmd.set_defaults(func=command_parse)

  scan_cmd = subparsers.add_parser("scan", help="Run an ATS-style resume simulation.")
  scan_cmd.add_argument("resume", type=Path, help="Resume file or application package directory.")
  scan_cmd.add_argument("--jd", type=Path, help="Job description file. Defaults to posting.md for application packages.")
  scan_cmd.add_argument("--skills-file", type=Path, help="Optional newline-delimited skill taxonomy.")
  scan_cmd.add_argument("--out", type=Path, help="Write JSON report to this path.")
  scan_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print JSON output instead of the terminal report.")
  scan_cmd.set_defaults(func=command_scan)

  compare_cmd = subparsers.add_parser("compare", help="Compare a resume to a job description.")
  compare_cmd.add_argument("resume", type=Path, help="Resume file or application package directory.")
  compare_cmd.add_argument("jd", type=Path, help="Job description file.")
  compare_cmd.add_argument("--skills-file", type=Path, help="Optional newline-delimited skill taxonomy.")
  compare_cmd.add_argument("--out", type=Path, help="Write JSON report to this path.")
  compare_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print JSON output instead of the terminal report.")
  compare_cmd.set_defaults(func=command_scan)

  keywords_cmd = subparsers.add_parser("keywords", help="Extract likely skills from a job description.")
  keywords_cmd.add_argument("jd", type=Path, help="Job description file.")
  keywords_cmd.add_argument("--skills-file", type=Path, help="Optional newline-delimited skill taxonomy.")
  keywords_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print JSON output.")
  keywords_cmd.set_defaults(func=command_keywords)

  suggest_cmd = subparsers.add_parser("suggest", help="Generate guarded ATS fix suggestions.")
  suggest_cmd.add_argument("resume", type=Path, help="Resume file or application package directory.")
  suggest_cmd.add_argument("--jd", type=Path, help="Job description file. Defaults to posting.md for application packages.")
  suggest_cmd.add_argument("--skills-file", type=Path, help="Optional newline-delimited skill taxonomy.")
  suggest_cmd.add_argument("--master", type=Path, default=DEFAULT_MASTER_RESUME, help="Master resume YAML/text used for evidence checks.")
  suggest_cmd.add_argument("--out-json", type=Path, help="Write suggestions JSON to this path.")
  suggest_cmd.add_argument("--out-md", type=Path, help="Write suggestions Markdown to this path.")
  suggest_cmd.add_argument("--prompt-out", type=Path, help="Write guarded LLM fix prompt to this path.")
  suggest_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print JSON output instead of Markdown.")
  suggest_cmd.set_defaults(func=command_suggest)

  draft_cmd = subparsers.add_parser("draft-diffs", help="Draft guarded ATS JSON diffs with an LLM backend.")
  draft_cmd.add_argument("resume", type=Path, help="Resume file or application package directory.")
  draft_cmd.add_argument(
    "--backend",
    choices=["opencode-sdk-zai", "opencode-zai", "opencode-cli-zai"],
    default="opencode-sdk-zai",
    help="LLM backend to use. `opencode-zai` is an alias for `opencode-sdk-zai`.",
  )
  draft_cmd.add_argument("--jd", type=Path, help="Job description file. Defaults to posting.md for application packages.")
  draft_cmd.add_argument("--skills-file", type=Path, help="Optional newline-delimited skill taxonomy.")
  draft_cmd.add_argument("--master", type=Path, default=DEFAULT_MASTER_RESUME, help="Master resume YAML/text used for evidence checks.")
  draft_cmd.add_argument("--suggestions", type=Path, help="Suggestions JSON. Defaults to artifacts/ats-suggestions.json for application packages.")
  draft_cmd.add_argument("--out-json", type=Path, help="Write raw drafted diffs JSON to this path.")
  draft_cmd.add_argument("--model", default=DEFAULT_OPENCODE_MODEL, help="OpenCode model, for example zai-coding-plan/glm-5.1.")
  draft_cmd.add_argument("--agent", default=DEFAULT_OPENCODE_AGENT, help="OpenCode agent name.")
  draft_cmd.add_argument("--opencode-bin", default="opencode", help="OpenCode executable name or path.")
  draft_cmd.add_argument("--sdk-runner", type=Path, default=DEFAULT_OPENCODE_SDK_RUNNER, help="Node OpenCode SDK runner path.")
  draft_cmd.add_argument("--timeout", type=int, default=180, help="OpenCode run timeout in seconds.")
  draft_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print raw drafted JSON output.")
  draft_cmd.set_defaults(func=command_draft_diffs)

  verify_cmd = subparsers.add_parser("verify-diffs", help="Verify LLM-proposed ATS diffs without applying them.")
  verify_cmd.add_argument("resume", type=Path, help="Resume file or application package directory.")
  verify_cmd.add_argument("--diffs", type=Path, required=True, help="Raw JSON diffs from an LLM runner.")
  verify_cmd.add_argument("--suggestions", type=Path, help="Suggestions JSON. Defaults to artifacts/ats-suggestions.json for application packages.")
  verify_cmd.add_argument("--out-json", type=Path, help="Write verified diff JSON to this path.")
  verify_cmd.add_argument("--out-md", type=Path, help="Write verified diff Markdown to this path.")
  verify_cmd.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="Print JSON output instead of Markdown.")
  verify_cmd.set_defaults(func=command_verify_diffs)

  return parser


def main(argv: Iterable[str] | None = None) -> int:
  parser = build_parser()
  args = parser.parse_args(list(argv) if argv is not None else None)
  try:
    return args.func(args)
  except RuntimeError as error:
    if getattr(args, "json", False):
      json_print({"ok": False, "error": {"type": "runtime_error", "message": str(error)}})
    else:
      print(f"atsim: {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
