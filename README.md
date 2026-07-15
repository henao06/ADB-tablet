# Proxy de responsividad

Expone tu app **local** bajo la IP de tu LAN para testear en una **tablet**,
sin que la app redirija afuera y sin tocar el código de la app.

## Por qué hace falta

La app decide a qué backend pegarle según `window.location.hostname`. Si no es
`localhost`, redirige al entorno por defecto. Además Moodle exige que le peguen
como `localhost` (si no, te tira 303) y el chatkit solo acepta CORS de `localhost`.

Este proxy resuelve las tres cosas a la vez:

1. **Host spoof** → reenvía `Host: localhost` a Moodle/Apache → Moodle responde JSON limpio.
2. **CORS** → inyecta el header en toda respuesta → el chatkit deja de bloquear.
3. **Rewrite al vuelo** → reescribe el bundle JS para que Moodle y chatkit sean
   relativos al origen del proxy. No modifica ningún archivo en disco.

## Uso

1. En tu PC:

   ```bash
   cd responsive-proxy
   ./start.sh          # o: node proxy.js
   ```

2. Averiguá la IP de tu PC en la LAN (ej. `192.168.3.155`):

   ```bash
   hostname -I
   ```

3. En la tablet (misma WiFi), abrí en Chrome:

   ```
   http://<IP-de-tu-PC>:8090/App/#/login
   ```

Vas a ver **exactamente** lo que ves en tu local, sin redirect, con datos de tu PC.

## Requisitos (tienen que estar corriendo en tu PC)

- App + Moodle en el puerto **80**
- chatkit en el puerto **8000**

## Config

- Puerto del proxy: variable `PROXY_PORT` (default `8090`).
- No requiere dependencias: solo Node.js.
# ADB-tablet
