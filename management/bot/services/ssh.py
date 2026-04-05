"""SSH-операции на exit-нодах (через cloudflared или напрямую)."""

import asyncio
import logging

log = logging.getLogger(__name__)


async def run_ssh(
    host: str,
    command: str,
    user: str = "root",
    port: int = 22,
    via_tunnel: bool = False,
    timeout: int = 120,
) -> tuple[int, str, str]:
    """Выполнить команду по SSH. Возвращает (exit_code, stdout, stderr)."""

    if via_tunnel:
        # SSH через Cloudflare Tunnel
        ssh_cmd = [
            "ssh", "-o", "StrictHostKeyChecking=no",
            "-o", f"ConnectTimeout={timeout}",
            "-o", f"ProxyCommand=cloudflared access ssh --hostname {host}",
            f"{user}@{host}",
            command,
        ]
    else:
        # Прямой SSH
        ssh_cmd = [
            "ssh", "-o", "StrictHostKeyChecking=no",
            "-o", f"ConnectTimeout={timeout}",
            "-p", str(port),
            f"{user}@{host}",
            command,
        ]

    log.info("SSH [%s]: %s", host, command[:100])

    proc = await asyncio.create_subprocess_exec(
        *ssh_cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=timeout
        )
    except asyncio.TimeoutError:
        proc.kill()
        return -1, "", "SSH timeout"

    return (
        proc.returncode,
        stdout.decode("utf-8", errors="replace").strip(),
        stderr.decode("utf-8", errors="replace").strip(),
    )


async def scp_to(
    host: str,
    local_path: str,
    remote_path: str,
    user: str = "root",
    port: int = 22,
) -> bool:
    """Скопировать файл на удалённый сервер."""
    cmd = [
        "scp", "-o", "StrictHostKeyChecking=no",
        "-P", str(port),
        local_path,
        f"{user}@{host}:{remote_path}",
    ]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    await proc.communicate()
    return proc.returncode == 0


async def test_ssh(
    host: str, user: str = "root", port: int = 22
) -> tuple[bool, str]:
    """Проверить SSH-доступ. Вернуть (ok, message)."""
    code, out, err = await run_ssh(
        host, "echo 'SSH_OK' && uname -a", user, port, timeout=15
    )
    if code == 0 and "SSH_OK" in out:
        return True, out.split("\n")[-1]  # uname вывод
    return False, err or out
