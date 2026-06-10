# Agent Guidelines

This document provides instructions for autonomous coding agents (such as Jules) working on the Autobot repository. Please adhere to these guidelines to ensure pull requests can be integrated cleanly and merged with minimal manual intervention.

## Git & Branching Workflow
- **Base Branch**: Always branch off the latest commit of the upstream repository's main branch (`crystal-autobot/autobot:main`). Sync your fork's `main` branch before starting work.
- **Focus**: Keep branches focused on a single change. Do not bundle unrelated modifications.

## Scope & Code Style Boundaries
- **Strict Scope**: Make modifications *only* to the files directly related to the task (e.g., fixing a bug, adding a specific feature, or optimizing a specific method).
- **No Unrelated Formatting Cleanups**: Do not run global or repository-wide formatting commands that modify style, whitespace, or trailing commas in unrelated files. 
- **Conform to Styling**: Follow the formatting established by the Crystal formatter (`crystal tool format`) and Ameba linter.

## Quality & Verification
- **Tests**: Write accompanying unit tests for new logic or modified behavior.
- **Validation**: Ensure that `crystal spec` passes completely and `bin/ameba src/` reports zero violations before proposing a PR.
