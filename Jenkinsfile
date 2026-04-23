// Multibranch: gestartet pro Branch. Startet/aktualisiert lang laufenden Vite-Dev-Server
// (siehe scripts/jenkins-vite-*.sh).

pipeline {
  agent any

  options {
    timestamps()
    // Build nicht endlos: Orchestrierung wartet max. in den Shell-Skripten
    timeout(time: 20, unit: 'MINUTES')
  }

  stages {
    stage('Vite remote devserver') {
      steps {
        sh '''
          set -e
          if [ -z "$WORKSPACE" ]; then
            echo "WORKSPACE fehlt" >&2
            exit 1
          fi
          chmod +x scripts/jenkins-*.sh 2>/dev/null || true
          bash scripts/jenkins-vite-pipeline-ctl.sh
        '''
      }
    }
  }
}
