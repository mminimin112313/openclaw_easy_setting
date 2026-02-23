# OpenClaw Easy Setting (Windows 초보자용)

이 저장소는 **아무것도 모르는 초보자**도 OpenClaw를 설치/실행할 수 있도록 만든 패키지입니다.

## 한 줄 요약

1. `bootstrap-openclaw-easy.bat` 더블클릭
2. 팝업에서 `예` 누르기
3. 설치 완료 후 열린 브라우저 화면에서 텔레그램 키/백업 암호 입력

## 무엇을 자동으로 하나요

- OpenClaw 원본 저장소 자동 클론
- 이 저장소의 안전한 설정 파일(overlay) 자동 적용
- Git / Docker Desktop 자동 설치(없을 때)
- Docker 실행 확인
- 개인정보/토큰 하드코딩 검사
- OpenClaw 이미지 빌드
- 원클릭 실행 및 설정 화면 열기

## 포함된 추가 스킬 (overlay)

- `openai-whisper`: 로컬 Whisper 전사
- `openai-whisper-api`: OpenAI Whisper API 전사
- `youtube-subs`: 유튜브 영상/플레이리스트 자막 다운로드
- `video-frames`: ffmpeg 기반 프레임/클립 추출

참고: `playwright` 이름의 별도 스킬 디렉터리는 없어서, 브라우저 자동화는 OpenClaw 내장 브라우저 기능 + 위 스킬 조합으로 사용합니다.

## 보안 원칙

- 토큰/암호를 저장소에 하드코딩하지 않음
- 백업 암호는 디스크에 저장하지 않고 실행 시 입력
- 관리자 포트는 기본 로컬 바인딩

## 실행 파일

- `bootstrap-openclaw-easy.bat` : 초보자용 시작 파일 (권장)
- `bootstrap-openclaw-easy.ps1` : PowerShell 버전
