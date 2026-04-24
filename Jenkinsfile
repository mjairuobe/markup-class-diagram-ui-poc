// Multibranch: Vite-Dev-Server nur über systemd --user + User-D-Bus (siehe deploy/INSTALL-jenkins-user-systemd.txt).

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
          # Zeilenweise Ausgabe erzwingen (stdout-Puffer), falls der Agent kein TTY nutzt
          if command -v stdbuf >/dev/null 2>&1; then
            stdbuf -oL -eL bash scripts/jenkins-vite-pipeline-ctl.sh
          else
            bash scripts/jenkins-vite-pipeline-ctl.sh
          fi
        '''
      }
    }
  }
}
