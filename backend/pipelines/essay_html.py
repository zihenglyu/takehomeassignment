from __future__ import annotations

import json
from typing import Any, Callable

from backend.artifacts.filesystem import ArtifactRun
from backend.pipelines.authorship import add_author_credit
from backend.pipelines.common import (
    PipelineError,
    PipelineResult,
    extract_fenced_or_raw,
    format_citations,
    format_log,
)
from backend.pipelines.html_to_pdf import (
    A4_PAGE,
    ConvertError,
    HtmlToPdfConverter,
)
from backend.providers.base import (
    ModelProviderError,
    TextGenerationProvider,
    TextGenerationRequest,
)
from backend.timing import RunTimingRecorder, measure_stage


def run_essay_html_pipeline(
    *,
    artifact_run: ArtifactRun,
    model_profile: dict[str, Any],
    model_provider: TextGenerationProvider,
    pdf_converter: HtmlToPdfConverter,
    task_text: str,
    context_bundle: str,
    output_preference: str | None,
    options: dict[str, Any] | None,
    search: dict[str, Any],
    max_output_tokens: int,
    emit_event: Callable[[str, str], None] | None = None,
    timing: RunTimingRecorder | None = None,
) -> PipelineResult:
    log_lines = [
        "Pipeline: essay_html",
        f"Output preference: {output_preference or 'pdf'}",
        "Stage: generate_source",
    ]
    system_prompt, user_prompt = build_essay_html_prompt(
        task_text=task_text,
        context_bundle=context_bundle,
        options=options or {},
        search=search,
    )
    if emit_event:
        emit_event("generate_source", "Generating essay HTML source")

    try:
        with measure_stage(timing, "provider_generation"):
            raw_output = model_provider.generate_text(
                TextGenerationRequest(
                    profile=model_profile,
                    system_prompt=system_prompt,
                    user_prompt=user_prompt,
                    max_output_tokens=max_output_tokens,
                    temperature=0.2,
                )
            )
    except ModelProviderError as exc:
        raise PipelineError(
            exc.code,
            exc.message,
            stage="generate_source",
            log_lines=log_lines,
        ) from exc
    except Exception as exc:
        raise PipelineError(
            "provider_unavailable",
            "The model provider request failed.",
            stage="generate_source",
            log_lines=log_lines,
        ) from exc

    source = extract_fenced_or_raw(raw_output, accepted_languages={"html", "htm"})
    source = add_author_credit(source.strip()) + "\n"
    html_path = artifact_run.write_output(
        "main.html",
        source,
        kind="source",
        media_type="text/html",
    )
    log_lines.extend(["Output: output/main.html", "Stage: convert_pdf"])
    if emit_event:
        emit_event("convert_pdf", "Converting essay HTML to PDF")

    pdf_path = artifact_run.run_dir / "output" / "main.pdf"
    try:
        with measure_stage(timing, "convert_pdf"):
            convert_result = pdf_converter.convert(
                html_path=html_path,
                pdf_path=pdf_path,
                page_config=A4_PAGE,
            )
    except ConvertError as exc:
        artifact_run.write_log("convert.log", exc.log_text)
        raise PipelineError(
            "convert_failed",
            exc.message,
            stage="convert_pdf",
            log_lines=log_lines,
        ) from exc
    except Exception as exc:
        artifact_run.write_log(
            "convert.log",
            "HTML-to-PDF converter raised an unexpected error.\n",
        )
        raise PipelineError(
            "convert_failed",
            "HTML-to-PDF conversion failed.",
            stage="convert_pdf",
            log_lines=log_lines,
        ) from exc

    artifact_run.write_log("convert.log", convert_result.log_text)
    artifact_run.write_output(
        "main.pdf",
        convert_result.pdf_path.read_bytes(),
        kind="pdf",
        media_type="application/pdf",
    )
    log_lines.extend(["Convert: pdf_ok", "Output: output/main.pdf"])
    return PipelineResult(log_text=format_log(log_lines))


REPORT_STRUCTURE_INSTRUCTION = (
    "When the task asks for an assignment report, deployment report, technical "
    "report, or reflective write-up, produce a professional academic report, not "
    "a chat answer. The finished document must be no more than 20 pages when "
    "printed on A4 paper with 20mm margins. Use this section order unless the "
    "task explicitly asks for another one: (1) title block with report title, "
    "student or author placeholder, course code, and date; (2) abstract of about "
    "120-180 words; (3) introduction stating objectives and how the marking "
    "criteria are addressed; (4) system and architecture overview with an inline "
    "SVG or CSS block diagram; (5) implementation and deployment walkthrough "
    "organised by task, covering local Docker build and run, image publication "
    "to a container registry, deployment on a cloud virtual machine, and the "
    "domain plus HTTPS reverse proxy; (6) verification and evidence, with "
    "numbered figures and tables tied to the captured screenshots and terminal "
    "output; (7) security analysis covering the classroom-grade application "
    "login, HTTPS, reverse-proxy access control, secret handling, firewall and "
    "security-group rules, and port exposure; (8) cost and operational analysis; "
    "(9) limitations and concrete improvements; (10) conclusion; (11) references. "
    "Use numbered headings such as 1, 1.1, and 1.2, and keep one consistent "
    "figure and table numbering scheme across the whole document."
)

EVIDENCE_INSTRUCTION = (
    "Ground the report in the deployment evidence supplied in the task text and "
    "prepared context. State evidence precisely instead of describing it vaguely: "
    "quote the exact commands that were run, the observed HTTP status codes, the "
    "container port mapping lines, the public IP URL, and the domain URL. When a "
    "screenshot is required but no image file is provided, insert a clearly "
    "labelled screenshot placeholder: a bordered figure box whose caption reads "
    "like \"Figure 2: Local web interface at http://127.0.0.1:14242/ui/ "
    "(screenshot placeholder)\". Never invent visual details, measurements, "
    "timings, log lines, or test results that were not supplied. For every step, "
    "explain why it was performed and what the resulting evidence proves, not "
    "only what the command does. Discuss trade-offs and risks honestly, "
    "including classroom-grade authentication, publicly exposed container "
    "ports, API-key handling, single-instance availability, and cloud running "
    "costs."
)

WRITING_QUALITY_INSTRUCTION = (
    "Write precise technical English in short paragraphs and active voice. "
    "Prefer tables for command-to-result mappings and for "
    "requirements-versus-implementation comparisons. Spell out every acronym at "
    "first use. Avoid marketing language, generic AI commentary, and repetition "
    "of the same point in several sections. Keep headings short and informative, "
    "and make sure every claim about the deployment can be traced to supplied "
    "evidence. If the request is a conventional essay rather than a deployment "
    "report, keep the same writing quality and evidence discipline but use a "
    "structure that suits the requested topic."
)


def build_essay_html_prompt(
    *,
    task_text: str,
    context_bundle: str,
    options: dict[str, Any],
    search: dict[str, Any],
) -> tuple[str, str]:
    system_prompt = (
        "You are an expert technical writer and teaching assistant who produces "
        "complete academic essay and report deliverables as self-contained HTML "
        "documents. You explain systems precisely, structure arguments clearly, "
        "and only claim evidence that the supplied material supports. Return only "
        "the requested HTML source, with no surrounding explanation."
    )
    output_instruction = (
        "Return one complete self-contained HTML document. It must start with "
        "<!doctype html> and include <html>, <head>, and <body>. Include all CSS "
        "inside a <style> element: use a readable serif academic print layout, "
        "clear heading hierarchy, careful paragraph spacing, and CSS "
        "@page { size: A4; margin: 20mm; }. Add print-aware layout rules: "
        "break-inside: avoid for figures, tables, and command blocks; "
        "break-after: avoid for headings; monospace blocks with a light border "
        "for shell commands; bordered figure boxes with captions; and page "
        "numbers where the renderer supports them. Do not use external "
        "stylesheet links, remote images, or remote HTTP(S) assets. If "
        "mathematical notation is needed, include inline KaTeX-compatible markup "
        "and any needed minimal KaTeX styling inline in the document; do not "
        "fetch KaTeX from a CDN at render time. Use inline SVG or CSS for "
        "diagrams. Cite any provided web sources in a References section using "
        "ordinary HTML. Do not wrap the answer in Markdown fences."
    )
    user_prompt = "\n\n".join(
        [
            "[Assignment Task]\n" + task_text.strip(),
            "[Prepared Context]\n" + context_bundle.strip(),
            "[Search Citations]\n" + format_citations(search),
            "[Options]\n" + json.dumps(options, sort_keys=True),
            "[Report Structure]\n" + REPORT_STRUCTURE_INSTRUCTION,
            "[Evidence And Integrity]\n" + EVIDENCE_INSTRUCTION,
            "[Writing Quality]\n" + WRITING_QUALITY_INSTRUCTION,
            "[Output Contract]\n" + output_instruction,
        ]
    )
    return system_prompt, user_prompt
