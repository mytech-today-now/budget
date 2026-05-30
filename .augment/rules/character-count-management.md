---
type: "always_apply"
---

# Character Count Management for .augment/ Directory

## Target Range

**Total character count of all files in `.augment/` directory: 48,599 - 49,299 characters**

## Extension System

**For content exceeding the character limit, use Augment Extensions:**

This repository provides an extension module system that allows unlimited content storage outside the `.augment/` folder. See [AGENTS.md](../../AGENTS.md) for details on how to use extension modules.

## Verification Command

```powershell
Get-ChildItem -Path ".augment" -Recurse -File | Get-Content -Raw | Measure-Object -Character | Select-Object -ExpandProperty Characters
```

## Character Reduction Priority (When Over Target)

### 1. Condense Examples (First Priority)
- Make examples more concise
- Keep 1-2 examples per concept maximum

### 2. Remove Examples (Second Priority)
- Remove least critical examples

### 3. Reduce Redundancy (Third Priority)
- Remove duplicate content
- Consolidate similar sections

### 4. Streamline Content (Fourth Priority)
- Use more concise language
- Combine related bullet points

## Content Preservation Rules

### NEVER Remove
- Core requirements and constraints
- Critical validation rules

### Always Preserve
- Specific, actionable guidance
- Technical accuracy and precision

## Validation Process

Before committing changes to `.augment/` files:
1. Run character count verification command
2. Verify total is within 48,599 - 49,299 range
3. If outside range, apply reduction/addition priorities
