import { NextResponse } from 'next/server';
import { ElevenLabsClient } from 'elevenlabs';

export async function GET() {
  const agentId = process.env.ELEVENLABS_AGENT_ID || process.env.AGENT_ID;
  if (!agentId) {
    console.error('ELEVENLABS_AGENT_ID (or AGENT_ID) is not set');
    return NextResponse.json({ error: 'Agent ID is not configured' }, { status: 500 });
  }

  try {
    const client = new ElevenLabsClient();
    const response = await client.conversationalAi.getSignedUrl({
      agent_id: agentId,
    });
    return NextResponse.json({ signedUrl: response.signed_url });
  } catch (error) {
    console.error('Error getting ElevenLabs signed URL:', error);
    return NextResponse.json({ error: 'Failed to get signed URL' }, { status: 500 });
  }
}


