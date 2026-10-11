# Estándares de Calidad: Formateador, Linter, Cobertura, Git Hooks y CI/CD

Este documento detalla la arquitectura de calidad de código, análisis estático y pruebas continuas implementada en los microservicios backend del ecosistema **SnippetSearcher** (`SnippetSearcher-Runner`, `SnippetSearcher-App` y `SnippetSearcher-AccessManager`), homologada con los estándares de **PrintScript-Tools**.

---

## 1. Visión General y Objetivos

Para garantizar mantenibilidad, consistencia estilística y robustez sin introducir código duplicado entre los repositorios, se integraron 5 pilares de ingeniería de software:

1. **Gradle Convention Plugin (`myPlugin`)**: Centralización de plugins y dependencias comunes mediante `buildSrc`.
2. **Formateador de Código (Ktlint)**: Unificación de sangrías, orden y estilo con `.editorconfig`.
3. **Linter Estático (Detekt)**: Análisis semántico y de complejidad de código con reglas idénticas a PrintScript.
4. **Verificación de Cobertura (JaCoCo)**: Validación automatizada de umbrales mínimos de cobertura de pruebas unitarias.
5. **Git Pre-commit Hook & CI/CD**: Doble barrera de control: ejecución local previa al commit (`.githooks/pre-commit`) y verificación en el pipeline remoto de GitHub Actions (`ci-cd.yml`).

---

## 2. Gradle Convention Plugin (`myPlugin` / `buildSrc`)

### A. Estructura del Módulo `buildSrc`
En cada uno de los microservicios backend se incorporó el módulo `buildSrc/`:

```text
<servicio>/
├── buildSrc/
│   ├── build.gradle
│   └── src/main/groovy/
│       ├── buildlogic.kotlin-myPlugin-conventions.gradle
│       └── myPlugin.gradle
```

* **`buildSrc/build.gradle`**:
  Configura `groovy-gradle-plugin` y expone las dependencias base (`kotlin-gradle-plugin:2.2.0`, `ktlint-gradle:12.1.0`, `detekt-gradle-plugin:1.23.8`).
* **`myPlugin.gradle`**:
  Alias que permite aplicar el plugin tanto con `id 'buildlogic.kotlin-myPlugin-conventions'` como con `id 'myPlugin'`.

### B. Funcionalidades de `myPlugin`
* **Lifecycle Logging**: Al ejecutarse cualquier tarea de Gradle, verifica su presencia activa mostrando:
  ```text
  >>>>> myPlugin is working <<<<<
  ```
* **Plugins integrados**:
  * `org.jetbrains.kotlin.jvm`
  * `org.jlleitschuh.gradle.ktlint`
  * `io.gitlab.arturbosch.detekt`
  * `jacoco`
* **Aislamiento y resolución de dependencias de compilador**:
  Spring Boot y Gradle 9 fuerzan versiones de Kotlin que entran en conflicto con el compilador embebido de Detekt 1.23.8 (`2.0.21`). El plugin resuelve esto dinámicamente mediante `afterEvaluate`:
  ```groovy
  project.afterEvaluate {
      project.configurations.matching { it.name.startsWith("detekt") }.configureEach {
          resolutionStrategy.eachDependency { DependencyResolveDetails details ->
              if (details.requested.group == 'org.jetbrains.kotlin') {
                  details.useVersion('2.0.21')
              }
          }
      }
  }
  ```
* **Enlace automático de hooks**:
  La tarea `test` depende automáticamente de `installGitHook`, asegurando que el hook de pre-commit se configure automáticamente al ejecutar pruebas.

---

## 3. Formateador de Código (Ktlint & `.editorconfig`)

Cada microservicio cuenta con un archivo [`.editorconfig`](file:///C:/Users/laris/Downloads/Ingsis/SnippetSearcher-Runner/.editorconfig) en su raíz:

```ini
[*.{kt,kts}]
indent_style = space
indent_size = 4
continuation_indent_size = 4
insert_final_newline = true
trim_trailing_whitespace = true

# Reglas desactivadas que generan conflictos o incompatibilidades
ktlint_standard_no-consecutive-blank-lines = disabled
ktlint_standard_import-ordering = disabled
ktlint_standard_argument-list-wrapping = disabled
```

### Comandos de formateo:
* **Formatear código automáticamente**:
  ```bash
  ./gradlew ktlintFormat
  ```
* **Verificar formato sin modificar**:
  ```bash
  ./gradlew ktlintCheck
  ```

---

## 4. Linter de Análisis Estático (Detekt)

### A. Reglas de Detekt (`config/detekt/detekt.yml`)
Cada repositorio posee el archivo [`config/detekt/detekt.yml`](file:///C:/Users/laris/Downloads/Ingsis/SnippetSearcher-Runner/config/detekt/detekt.yml) idéntico al de **PrintScript-Tools** (799 líneas de configuración), que audita:
* **Empty blocks**: Detección de bloques `catch`, `finally`, `if`, `while` o funciones vacías.
* **Naming conventions**: Patrones de nomenclatura de clases (`PascalCase`), variables y funciones (`camelCase`), paquetes y constantes.
* **Style**: Límite de longitud de línea (máx. 140 caracteres), saltos de línea al final del archivo y limpieza de espacios redundantes.
* **Exclusiones de tests**: Las pruebas unitarias están explícitamente excluidas de reglas de nomenclatura restrictivas (`**/test/**`).

### B. Ejecución:
```bash
./gradlew detekt
```

---

## 5. Cobertura de Código (JaCoCo)

Cada servicio reporta y verifica métricas de cobertura de código mediante el plugin JaCoCo:

* **Generación de reportes**: Genera reportes en formato XML y HTML bajo `build/reports/jacoco/test/html/`.
  ```bash
  ./gradlew jacocoTestReport
  ```
* **Verificación de umbral**: Comprueba que la cobertura supere el mínimo establecido para el microservicio:
  ```bash
  ./gradlew jacocoTestCoverageVerification
  ```
* **Exclusiones técnicas**: No se penaliza cobertura sobre DTOs, configuraciones de infraestructura de Spring ni clases de punto de entrada (`ApplicationKt`).

---

## 6. Git Pre-commit Hook

### A. Instalación automática
En el `build.gradle` de cada servicio se registró la tarea:
```groovy
def srcHookPath = "${rootDir}/.githooks/pre-commit"
def hookFilePath = "${rootDir}/.git/hooks/pre-commit"

tasks.register("installGitHook") {
    def srcHook = file(srcHookPath)
    def hookFile = file(hookFilePath)

    outputs.file(hookFile)

    doLast {
        if (!srcHook.exists()) {
            println "No hook found in .githooks/pre-commit"
            return
        }

        hookFile.parentFile.mkdirs()
        hookFile.text = srcHook.text
        hookFile.setExecutable(true)
        println "Pre-commit was installed/updated in .git/hooks/"
    }
}
```
Para instalarlo o actualizarlo manualmente:
```bash
./gradlew installGitHook
```

### B. Flujo de Ejecución del Hook (`.githooks/pre-commit`)
Cada vez que un desarrollador ejecuta `git commit`, el hook ejecuta secuencialmente:

1. **`ktlintFormat`**: Aplica formato. Si detecta diferencias entre antes y después, **bloquea el commit** para que el desarrollador revise los cambios con `git diff`, los agregue con `git add` y vuelva a commitear.
2. **`detekt`**: Ejecuta el análisis estático. Si hay infracciones de calidad, **bloquea el commit**.
3. **`test`**: Ejecuta los tests unitarios. Si alguno falla, muestra el log de error y **bloquea el commit**.
4. **`jacocoTestCoverageVerification`**: Verifica el umbral de cobertura. Si es inferior al requerido, **bloquea el commit**.
5. Si todas las etapas pasan con éxito, emite `Todo aprobado. Commit permitido.` y permite la creación del commit.

---

## 7. Integración en el Pipeline Remoto de CI/CD (`ci-cd.yml`)

En los flujos de GitHub Actions (`.github/workflows/ci-cd.yml`) de los tres microservicios se homologaron los pasos de verificación previa a la construcción de contenedores:

```yaml
      - name: Run ktlintFormat
        run: |
          CHANGES_BEFORE=$(git diff --name-only)
          ./gradlew ktlintFormat --quiet
          CHANGES_AFTER=$(git diff --name-only)
          if [ "$CHANGES_BEFORE" != "$CHANGES_AFTER" ]; then
            echo "Build bloqueado: ktlintFormat modificó archivos."
            exit 1
          fi

      - name: Run ktlintCheck
        run: ./gradlew ktlintCheck --quiet

      - name: Run Detekt
        run: ./gradlew detekt

      - name: Run tests
        run: |
          ./gradlew test --continue > .git/test-output.log
          if grep -q "FAILED" .git/test-output.log; then
            echo "Build bloqueado: fallaron tests."
            cat .git/test-output.log | grep FAILED
            exit 1
          fi

      - name: Verify coverage
        run: |
          if ! ./gradlew jacocoTestCoverageVerification --quiet; then
            echo "Build bloqueado: cobertura de código no cumple los requisitos."
            ./gradlew jacocoTestReport
            exit 1
          fi

      - name: Upload JaCoCo coverage report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: jacoco-report
          path: build/reports/jacoco/test/html/

      - name: Build
        run: ./gradlew build -x test
```

> [!NOTE]
> La infraestructura de despliegue a los servidores (construcción de imágenes Docker, publicación en GHCR, conexión SSH a las VMs de Azure y actualización de réplicas en Docker Swarm) se mantiene estrictamente intacta y desacoplada de las verificaciones de código fuente.

---

## 8. Matriz de Estado por Repositorio

| Microservicio | Plugin `myPlugin` | `.editorconfig` | Detekt (`detekt.yml`) | Pre-commit Hook | CI/CD Remoto | Ramas Sincronizadas |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **`SnippetSearcher-Runner`** | ✅ Implementado | ✅ Activo | ✅ 0 errores | ✅ Instalado | ✅ Homologado | `develop` y `production` |
| **`SnippetSearcher-App`** | ✅ Implementado | ✅ Activo | ✅ 0 errores | ✅ Instalado | ✅ Homologado | `develop` y `production` |
| **`SnippetSearcher-AccessManager`** | ✅ Implementado | ✅ Activo | ✅ 0 errores | ✅ Instalado | ✅ Homologado | `develop` y `production` |
| **`printscript-ui`** | N/A (Frontend) | N/A | N/A | N/A | N/A | `develop` y `production` |
| **`SnippetSearcher-Infrastructure`** | N/A (Infra) | N/A | N/A | N/A | N/A | `develop` y `main` |
