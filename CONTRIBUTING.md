# Contributing to Lembos deploy

Thank you for your interest in contributing to Lembos! To keep the project sustainable, we require all
contributors to agree to our [Contributor License Agreement (CLA)](./CLA.md).

## How to contribute

1. Fork the repo.
2. Create your feature branch.
3. **Important:** By submitting a Pull Request, you agree to the terms of the Lembos IDP CLA.
4. Submit your PR.

Changes to the platform itself — its services, images and configuration contract — belong in
[lembosproj/platform](https://github.com/lembosproj/platform). This repository installs what that one
publishes.

## Before you open a pull request

The `Chart` workflow runs the same checks; run them locally first:

```shell
helm repo add dandydeveloper https://dandydeveloper.github.io/charts
helm repo add temporal https://go.temporal.io/helm-charts
helm dependency build charts/lembos
helm lint charts/lembos -f charts/lembos/ci/default-values.yaml
```

A change to a value that is part of the platform's configuration contract (the `platform` section of
`values.yaml`) needs the matching change in the platform's `PlatformConfig`. A secret added to the setup job
needs the matching change to the platform's `LocalSetupSpec`. Nothing checks either; the reviewer does.

## Spot a Typo?

Typos and other small fixes are important to us — no contribution is too small! If you spot something small,
go ahead and open a Pull Request. For these types of contributions, there's no need to create a separate issue.

## Have a Suggestion?

If you have a suggestion, please open an issue with:

- A clear title and description of the suggestion
- The cluster, controller or cloud it concerns, when it is specific to one
- Whether you're interested in implementing it yourself

## Code of Conduct

To ensure a welcoming and positive environment for everyone, please adhere to our
[Code of Conduct](./CODE-OF-CONDUCT.md). Respectful collaboration is key to a successful project.
